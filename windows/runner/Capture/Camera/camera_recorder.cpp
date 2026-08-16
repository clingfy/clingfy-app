#include "Capture/Camera/camera_recorder.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <future>
#include <memory>
#include <utility>

#include "Bridge/Devices/device_probe_log.h"
#include "Capture/Camera/camera_format.h"
#include "Encoding/mf_encoder_config.h"

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

constexpr std::int64_t kHundredNanosPerSecond = 10'000'000;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), needed);
  return wide;
}

// Compute a sane H.264 bitrate from the capture geometry, clamped to a safe
// band so a tiny camera isn't starved and a 1080p one isn't bloated.
std::uint32_t ResolveBitrate(std::uint32_t width, std::uint32_t height,
                             std::uint32_t fps) {
  const std::uint32_t raw = width * height * std::max<std::uint32_t>(fps, 1) / 8;
  return std::clamp<std::uint32_t>(raw, 2'000'000u, 8'000'000u);
}

}  // namespace

CameraRecorder::CameraRecorder() = default;

CameraRecorder::~CameraRecorder() { Stop(); }

std::int64_t CameraRecorder::NextSampleTimeHns(std::int64_t elapsed_hns,
                                               std::int64_t& first_hns,
                                               std::int64_t& last_hns) {
  if (first_hns < 0) {
    first_hns = elapsed_hns;
  }
  std::int64_t rebased = elapsed_hns - first_hns;
  if (rebased < 0) {
    rebased = 0;
  }
  // Strictly increasing — the H.264 sink writer rejects tied/decreasing times.
  if (last_hns >= 0 && rebased <= last_hns) {
    rebased = last_hns + 1;
  }
  last_hns = rebased;
  return rebased;
}

std::int64_t CameraRecorder::NowHns() {
  std::lock_guard<std::mutex> lock(clock_mutex_);
  return clock_.ElapsedHns();
}

bool CameraRecorder::Start(const Config& config) {
  config_ = config;
  stop_.store(false);
  paused_.store(false);
  device_lost_.store(false);
  frames_written_.store(0);
  first_frame_hns_ = -1;
  last_sample_hns_ = -1;
  last_preview_hns_ = -1;
  stopped_ = false;
  result_ = Result{};

  // Mark the camera's pause-aware clock HERE, on the engine thread, before the
  // device-open thread spawns — exactly like the cursor sampler. The clock then
  // runs during device warm-up, so the first frame's elapsed time (the raw.mov
  // rebase origin) includes that latency, and `base_offset_hns` aligns it to the
  // engine timeline.
  {
    std::lock_guard<std::mutex> lock(clock_mutex_);
    clock_.MarkStart();
  }

  // shared_ptr (not a bare promise) so the report callback is copyable — a
  // move-only promise cannot live inside std::function. The promise outlives
  // Start via the thread's copy; set_value fires exactly once.
  auto open_promise = std::make_shared<std::promise<bool>>();
  std::future<bool> open_future = open_promise->get_future();
  std::function<void(bool)> report_open = [open_promise](bool ok) {
    open_promise->set_value(ok);
  };

  thread_ = std::thread(&CameraRecorder::ThreadMain, this, std::move(report_open));

  // Phase 10.4: bounded wait. A wedged MF Frame Server can block the open
  // sequence (MFCreateDeviceSource et al.) indefinitely; without a deadline
  // that wedges startRecording — and the engine mutex — forever. On timeout
  // the worker cannot be joined (it is blocked inside MF), so it is DETACHED
  // and this object must be kept alive by the caller for the process
  // lifetime (see open_timed_out()). The worker self-terminates when the
  // open eventually completes and it notices `abandoned_`.
  const auto timeout = std::chrono::milliseconds(
      config_.open_timeout_ms > 0 ? config_.open_timeout_ms : 10000);
  if (open_future.wait_for(timeout) == std::future_status::timeout) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraRecorder: device open timed out; abandoning the camera "
        "(screen recording continues)");
    abandoned_.store(true);
    open_timed_out_ = true;
    thread_.detach();
    started_ = false;
    return false;
  }

  const bool ok = open_future.get();
  if (!ok) {
    // The thread reported a failed open and is winding down on its own; signal
    // stop and join so we leave no dangling thread.
    stop_.store(true);
    if (thread_.joinable()) {
      thread_.join();
    }
    started_ = false;
    return false;
  }
  started_ = true;
  return true;
}

void CameraRecorder::Pause() {
  paused_.store(true);
  std::lock_guard<std::mutex> lock(clock_mutex_);
  clock_.Pause();
}

void CameraRecorder::Resume() {
  {
    std::lock_guard<std::mutex> lock(clock_mutex_);
    clock_.Resume();
  }
  paused_.store(false);
}

CameraRecorder::Result CameraRecorder::Stop() {
  if (stopped_) {
    return result_;
  }
  stop_.store(true);
  if (thread_.joinable()) {
    thread_.join();
  }
  // The capture thread has exited — width_/fps_/first_frame_hns_ are now stable.
  result_.width = width_;
  result_.height = height_;
  result_.fps = fps_;
  result_.frames_written = frames_written_.load();
  result_.device_lost = device_lost_.load();
  result_.device_id = config_.device_symlink;
  // Engine-relative time of the first frame: the camera-clock elapsed at that
  // frame (which includes device-open latency, since the clock was marked in
  // Start) plus the engine's elapsed at camera start.
  result_.start_offset_ms =
      first_frame_hns_ >= 0
          ? (config_.base_offset_hns + first_frame_hns_) / 10000
          : 0;
  stopped_ = true;
  return result_;
}

void CameraRecorder::ThreadMain(std::function<void(bool)> report_open) {
  // The device source + source reader + sink writer are all created and used on
  // THIS thread (its own MTA apartment) to avoid cross-apartment marshaling.
  const HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT mf = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);

  ComPtr<IMFMediaSource> source;
  ComPtr<IMFSourceReader> reader;
  ComPtr<IMFSinkWriter> writer;
  DWORD writer_stream = 0;
  bool opened = false;

  auto cleanup = [&]() {
    reader.Reset();
    writer.Reset();
    if (source) {
      source->Shutdown();
      source.Reset();
    }
    if (SUCCEEDED(mf)) {
      ::MFShutdown();
    }
    if (SUCCEEDED(co)) {
      ::CoUninitialize();
    }
  };

  if (FAILED(mf)) {
    report_open(false);
    cleanup();
    return;
  }

  // ---- Open the device ----------------------------------------------------
  const std::wstring symlink = Utf8ToWide(config_.device_symlink);
  ComPtr<IMFAttributes> dev_attrs;
  if (symlink.empty() ||
      FAILED(::MFCreateAttributes(dev_attrs.GetAddressOf(), 2)) ||
      FAILED(dev_attrs->SetGUID(
          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)) ||
      FAILED(dev_attrs->SetString(
          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
          symlink.c_str())) ||
      FAILED(::MFCreateDeviceSource(dev_attrs.Get(), source.GetAddressOf())) ||
      source == nullptr) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraRecorder: failed to open the selected camera device");
    report_open(false);
    cleanup();
    return;
  }

  // ---- Source reader (let MF insert a converter for our requested type) ---
  ComPtr<IMFAttributes> reader_attrs;
  if (FAILED(::MFCreateAttributes(reader_attrs.GetAddressOf(), 1)) ||
      FAILED(reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
                                     TRUE)) ||
      FAILED(::MFCreateSourceReaderFromMediaSource(
          source.Get(), reader_attrs.Get(), reader.GetAddressOf())) ||
      reader == nullptr) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraRecorder: failed to create the camera source reader");
    report_open(false);
    cleanup();
    return;
  }

  // ---- Learn the native geometry, choose a safe target --------------------
  std::uint32_t native_w = 0;
  std::uint32_t native_h = 0;
  std::uint32_t fps_num = 0;
  std::uint32_t fps_den = 0;
  {
    ComPtr<IMFMediaType> native;
    if (SUCCEEDED(reader->GetNativeMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
            native.GetAddressOf())) &&
        native != nullptr) {
      ::MFGetAttributeSize(native.Get(), MF_MT_FRAME_SIZE, &native_w,
                           &native_h);
      ::MFGetAttributeRatio(native.Get(), MF_MT_FRAME_RATE, &fps_num, &fps_den);
    }
  }
  const CameraDimensions target =
      ChooseCameraTargetResolution(native_w, native_h);
  std::uint32_t fps = ChooseCameraFps(fps_num, fps_den);
  fps = std::min(fps, std::max<std::uint32_t>(config_.target_fps, 1u));

  // ---- Negotiate the reader output subtype (NV12 then RGB32) --------------
  GUID input_subtype = MFVideoFormat_NV12;
  bool format_ok = false;
  for (const GUID candidate : {MFVideoFormat_NV12, MFVideoFormat_RGB32}) {
    ComPtr<IMFMediaType> want;
    if (FAILED(::MFCreateMediaType(want.GetAddressOf()))) {
      continue;
    }
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, candidate);
    want->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    ::MFSetAttributeSize(want.Get(), MF_MT_FRAME_SIZE, target.width,
                         target.height);
    ::MFSetAttributeRatio(want.Get(), MF_MT_FRAME_RATE, fps, 1);
    ::MFSetAttributeRatio(want.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (SUCCEEDED(reader->SetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
            want.Get()))) {
      input_subtype = candidate;
      format_ok = true;
      break;
    }
  }
  if (!format_ok) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraRecorder: camera does not support an NV12/RGB32 output");
    report_open(false);
    cleanup();
    return;
  }

  // Read back the actually-negotiated size (the converter may have clamped it).
  std::uint32_t width = target.width;
  std::uint32_t height = target.height;
  {
    ComPtr<IMFMediaType> current;
    if (SUCCEEDED(reader->GetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
            current.GetAddressOf())) &&
        current != nullptr) {
      std::uint32_t cw = 0;
      std::uint32_t ch = 0;
      if (SUCCEEDED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &cw,
                                         &ch)) &&
          cw > 0 && ch > 0) {
        width = cw & ~1u;
        height = ch & ~1u;
      }
    }
  }

  // ---- Sink writer: H.264 .mov (video only) -------------------------------
  const std::wstring out_path = Utf8ToWide(config_.temp_raw_path);
  if (out_path.empty() ||
      FAILED(::MFCreateSinkWriterFromURL(out_path.c_str(), nullptr, nullptr,
                                         writer.GetAddressOf())) ||
      writer == nullptr) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraRecorder: failed to create the camera sink writer");
    report_open(false);
    cleanup();
    return;
  }
  {
    ComPtr<IMFMediaType> out_type;
    ComPtr<IMFMediaType> in_type;
    if (FAILED(::MFCreateMediaType(out_type.GetAddressOf())) ||
        FAILED(::MFCreateMediaType(in_type.GetAddressOf()))) {
      report_open(false);
      cleanup();
      return;
    }
    out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    out_type->SetUINT32(MF_MT_AVG_BITRATE, ResolveBitrate(width, height, fps));
    out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    // Issue #294, camera sidecar. This is a SECOND, independent sink writer —
    // it does not go through MfSinkWriterEncoder — and the preview seeks into
    // camera/raw.mov on every backward jump, so it pays its own lead-in and
    // needs its own pin. Same rule, from the same shared helper.
    if (const std::uint32_t gop =
            clingfy::encoding::ResolveKeyframeIntervalFrames(fps);
        gop > 0) {
      out_type->SetUINT32(MF_MT_MAX_KEYFRAME_SPACING, gop);
    }
    ::MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE, width, height);
    ::MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE, fps, 1);
    ::MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

    in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in_type->SetGUID(MF_MT_SUBTYPE, input_subtype);
    in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    ::MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, width, height);
    ::MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE, fps, 1);
    ::MFSetAttributeRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

    if (FAILED(writer->AddStream(out_type.Get(), &writer_stream)) ||
        FAILED(writer->SetInputMediaType(writer_stream, in_type.Get(),
                                         nullptr)) ||
        FAILED(writer->BeginWriting())) {
      clingfy::bridge::devices::LogDeviceProbe(
          "CameraRecorder: failed to configure the camera sink writer");
      report_open(false);
      cleanup();
      return;
    }
  }

  // Geometry is final — publish it for Stop() (read after join). The clock was
  // already marked in Start() (engine thread), so it has been running through
  // the device-open above; the first captured frame's elapsed time therefore
  // includes that warm-up latency.
  width_ = width;
  height_ = height;
  fps_ = fps;

  // Phase 9.3: prepare the live-preview scratch buffer (only when a sink is
  // attached — no sink means zero preview cost). RGB32 from MF is BGRA in
  // memory; everything else here is NV12.
  preview_format_ = (input_subtype == MFVideoFormat_NV12)
                        ? CameraPixelFormat::kNv12
                        : CameraPixelFormat::kBgra32;
  if (config_.on_preview_frame) {
    const PreviewSize ps = ComputePreviewSize(
        static_cast<int>(width_), static_cast<int>(height_),
        config_.preview_max_dim);
    preview_w_ = ps.width;
    preview_h_ = ps.height;
    preview_bgra_.assign(
        static_cast<size_t>(preview_w_) * preview_h_ * 4, 0);
  }

  opened = true;
  report_open(true);

  // Phase 10.4: Start() may have timed out a moment before the open report
  // landed. An abandoned recorder has no consumer — close our own resources
  // and exit instead of capturing into the void (nobody will ever Stop us).
  if (abandoned_.load()) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraRecorder: open completed after abandonment; exiting");
    cleanup();
    return;
  }

  // ---- Capture loop -------------------------------------------------------
  const std::int64_t sample_duration = kHundredNanosPerSecond / std::max(fps, 1u);
  bool warned_lost = false;
  while (!stop_.load() && !abandoned_.load()) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    const HRESULT hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
        &flags, &ts, sample.GetAddressOf());
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR)) {
      device_lost_.store(true);
      if (!warned_lost && config_.on_device_lost) {
        warned_lost = true;
        config_.on_device_lost();
      }
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;  // stream tick / gap — no frame this read.
    }
    if (paused_.load()) {
      continue;  // drop frames captured while paused.
    }
    const std::int64_t elapsed = NowHns();
    const std::int64_t out_hns =
        NextSampleTimeHns(elapsed, first_frame_hns_, last_sample_hns_);
    sample->SetSampleTime(out_hns);
    sample->SetSampleDuration(sample_duration);
    if (SUCCEEDED(writer->WriteSample(writer_stream, sample.Get()))) {
      frames_written_.fetch_add(1, std::memory_order_relaxed);
    }

    // Phase 9.3: best-effort live preview. AFTER WriteSample (so the encode is
    // never delayed) and throttled to ~15fps, convert the frame to downscaled
    // BGRA and hand it to the overlay. Any failure here simply skips a preview
    // frame — recording is never affected.
    if (config_.on_preview_frame && preview_w_ > 0 && preview_h_ > 0) {
      constexpr std::int64_t kPreviewIntervalHns = kHundredNanosPerSecond / 15;
      if (last_preview_hns_ < 0 ||
          elapsed - last_preview_hns_ >= kPreviewIntervalHns) {
        ComPtr<IMFMediaBuffer> buf;
        if (SUCCEEDED(sample->GetBufferByIndex(0, buf.GetAddressOf())) && buf) {
          BYTE* data = nullptr;
          DWORD cur = 0;
          if (SUCCEEDED(buf->Lock(&data, nullptr, &cur)) && data != nullptr) {
            const bool is_bgra = preview_format_ == CameraPixelFormat::kBgra32;
            const int src_stride = is_bgra ? static_cast<int>(width_) * 4
                                           : static_cast<int>(width_);
            const size_t needed =
                is_bgra ? static_cast<size_t>(width_) * 4 * height_
                        : static_cast<size_t>(width_) * height_ * 3 / 2;
            if (cur >= needed &&
                ConvertToBgra(preview_format_, data, static_cast<int>(width_),
                              static_cast<int>(height_), src_stride,
                              preview_bgra_.data(), preview_w_, preview_h_)) {
              config_.on_preview_frame(preview_bgra_.data(), preview_w_,
                                       preview_h_);
              last_preview_hns_ = elapsed;
            }
            buf->Unlock();
          }
        }
      }
    }
  }

  if (opened && writer) {
    writer->Finalize();
  }
  cleanup();
}

}  // namespace clingfy::capture
