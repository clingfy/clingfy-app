#include "Capture/Export/export_pipeline.h"

#include <d3d11.h>
#include <d3d11_4.h>
#include <d2d1_1.h>
#include <d2d1_1helper.h>
#include <d2d1effects.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>

#include "Audio/audio_mixer.h"
#include "Capture/Camera/camera_export_layout.h"
#include "Capture/Camera/camera_export_renderer.h"
#include "Capture/Cursor/cursor_export_renderer.h"
#include "Capture/Zoom/zoom_export_controller.h"
#include "Bridge/native_log_publisher.h"
#include "Capture/Export/clip_audio_stitch.h"
#include "Capture/Export/color_grade.h"
#include "Capture/Export/export_audio.h"
#include "Graphics/color_grade_effect.h"
#include "Capture/Export/export_format.h"
#include "Capture/Background/background_image_cache.h"
#include "Capture/Background/preset_bitmap_cache.h"
#include "Capture/Export/export_geometry.h"
#include "Capture/Export/gif_export_policy.h"
#include "Capture/Export/reorder_audio_pump.h"
#include "Capture/captured_video_frame.h"
#include "Encoding/gif_encoder.h"
#include "Encoding/mf_encoder_config.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture::export_ {

namespace {

using Microsoft::WRL::ComPtr;

// Sentinel for "stream not found" — distinguishable from any concrete
// stream index (which start at 0) and from MF's symbolic selectors.
constexpr DWORD kNoStream = 0xFFFFFFFFu;

// The canonical export audio format the source reader is negotiated to
// (48 kHz stereo int16 PCM). Shared by the media-type setup and the clip
// audio stitch so the ms<->frame math and the decoded layout agree.
constexpr std::int64_t kExportAudioSampleRate = 48'000;
constexpr std::uint32_t kExportAudioChannels = 2;

// Seek an IMFSourceReader to a recording-relative millisecond position.
// Editing port (clips, 3b-2): reorder export reads each kept range's source
// window in timeline order, which means seeking the reader BACKWARD across a
// range boundary. MF seeks to the nearest prior keyframe; the caller decodes
// forward, discarding the lead-in, until the range window is reached.
void SeekSourceReader(IMFSourceReader* reader, std::int64_t source_ms) {
  if (reader == nullptr) {
    return;
  }
  PROPVARIANT pos;
  PropVariantInit(&pos);
  pos.vt = VT_I8;
  pos.hVal.QuadPart = std::max<std::int64_t>(0, source_ms) * 10000;
  reader->SetCurrentPosition(GUID_NULL, pos);
  PropVariantClear(&pos);
}

// Idempotent MF startup. Mirrors the encoder's pattern: paired with
// MFShutdown only at process exit, so opening an export does not churn
// global MF state. A second independent once_flag (the encoder has its
// own) simply bumps MFStartup's internal refcount, which is harmless.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  std::call_once(flag, [] { ::MFStartup(MF_VERSION, MFSTARTUP_LITE); });
}

// Build a failed result and best-effort remove any partial output at
// `destination_path` (Phase 10.4): a failed render must never leave a
// corrupt file (e.g. a moov-less MP4 after a failed Finalize, or a
// truncated GIF) at the user-chosen destination. The destination is always
// freshly created via UniqueDestination, so removal can never clobber a
// pre-existing user file; before the encoder opens, the file does not exist
// yet and the remove is a harmless no-op. `disk_full` marks a failure whose
// encoder error carried a disk-full HRESULT. `destination_path` is UTF-8.
RenderResult Failure(const std::string& destination_path, std::string message,
                     bool disk_full = false, bool device_removed = false) {
  if (!destination_path.empty()) {
    std::error_code ec;
    std::filesystem::remove(std::filesystem::u8path(destination_path), ec);
  }
  RenderResult out;
  out.ok = false;
  out.disk_full = disk_full;
  out.device_removed = device_removed;
  out.message = std::move(message);
  return out;
}

// Slice 5A: build a cancelled result and remove any partial output file. The
// message contains "cancelled" so the Dart side classifies it as a clean
// cancel (post_processing_controller._isLikelyCancellationMessage), not a
// failure. `destination_path` is UTF-8.
RenderResult Cancelled(const std::string& destination_path) {
  if (!destination_path.empty()) {
    std::error_code ec;
    std::filesystem::remove(std::filesystem::u8path(destination_path), ec);
  }
  RenderResult out;
  out.ok = false;
  out.cancelled = true;
  out.message = "export: cancelled by user";
  return out;
}

std::string Hr(const char* what, HRESULT hr) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), " (hr=0x%08lX)", static_cast<unsigned long>(hr));
  return std::string(what) + buf;
}

// Like Hr, but appends the device-removed reason when the failure is (or is
// caused by) a lost D3D device — the discriminator between "GPU ran out of
// memory" and "the device was reset under us" (driver reset, Modern Standby
// resume, TDR). A 55-min-recording export failure was undiagnosable because
// this distinction never reached the logs.
std::string HrWithDeviceState(const char* what, HRESULT hr,
                              ID3D11Device* device) {
  std::string message = Hr(what, hr);
  if (device != nullptr) {
    const HRESULT removed = device->GetDeviceRemovedReason();
    if (removed != S_OK) {
      char buf[48];
      std::snprintf(buf, sizeof(buf), " (device removed, reason=0x%08lX)",
                    static_cast<unsigned long>(removed));
      message += buf;
    }
  }
  return message;
}

// Walk the source's streams, selecting only the first video stream (and
// the first audio stream, if any) and recording their concrete indices.
// Returns kNoStream for a track that is absent.
void IdentifyStreams(IMFSourceReader* reader, DWORD* video_index,
                     DWORD* audio_index) {
  *video_index = kNoStream;
  *audio_index = kNoStream;
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  for (DWORD i = 0;; ++i) {
    ComPtr<IMFMediaType> native;
    const HRESULT hr = reader->GetNativeMediaType(i, 0, native.GetAddressOf());
    if (hr == MF_E_INVALIDSTREAMNUMBER) {
      break;
    }
    if (FAILED(hr) || native == nullptr) {
      continue;
    }
    GUID major = GUID_NULL;
    if (FAILED(native->GetGUID(MF_MT_MAJOR_TYPE, &major))) {
      continue;
    }
    if (major == MFMediaType_Video && *video_index == kNoStream) {
      *video_index = i;
    } else if (major == MFMediaType_Audio && *audio_index == kNoStream) {
      *audio_index = i;
    }
  }
}

// Copy one decoded BGRA video frame into a top-down, tightly-packed
// buffer (`dest`, sized width*4*height) regardless of the source buffer's
// stride sign. IMF2DBuffer::Lock2D hands back a pointer to the top row
// plus a stride that may be negative for bottom-up layouts; indexing by
// `scan0 + row * stride` always walks top-to-bottom either way. Returns
// false on lock failure.
bool ExtractTopDownBgra(IMFSample* sample, UINT width, UINT height,
                        std::vector<BYTE>* dest) {
  const size_t row_bytes = static_cast<size_t>(width) * 4u;
  dest->resize(row_bytes * height);

  ComPtr<IMFMediaBuffer> raw;
  if (FAILED(sample->GetBufferByIndex(0, raw.GetAddressOf())) ||
      raw == nullptr) {
    return false;
  }

  ComPtr<IMF2DBuffer> buffer2d;
  if (SUCCEEDED(raw.As(&buffer2d)) && buffer2d != nullptr) {
    BYTE* scan0 = nullptr;
    LONG stride = 0;
    if (FAILED(buffer2d->Lock2D(&scan0, &stride)) || scan0 == nullptr) {
      return false;
    }
    for (UINT row = 0; row < height; ++row) {
      const BYTE* src_row = scan0 + static_cast<LONG>(row) * stride;
      std::memcpy(dest->data() + row * row_bytes, src_row, row_bytes);
    }
    buffer2d->Unlock2D();
    return true;
  }

  // Fallback: a plain contiguous buffer. Assume a top-down, tightly
  // packed layout (the common case for a Video-Processor RGB32 output).
  ComPtr<IMFMediaBuffer> contiguous;
  if (FAILED(sample->ConvertToContiguousBuffer(contiguous.GetAddressOf())) ||
      contiguous == nullptr) {
    return false;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0;
  DWORD cur_len = 0;
  if (FAILED(contiguous->Lock(&data, &max_len, &cur_len)) || data == nullptr) {
    return false;
  }
  const size_t copy_bytes =
      (cur_len < dest->size()) ? cur_len : dest->size();
  std::memcpy(dest->data(), data, copy_bytes);
  contiguous->Unlock();
  return true;
}

// Slice 4 normalize support: decode the whole audio track once (a second,
// independent source reader, audio-only) and return the peak linear level in
// [0, 1]. Mirrors macOS `estimateAudioPeakLinear`, which likewise opens its
// own reader independent of the render decode. Returns 0.0 when there is no
// audio or it can't be decoded — the caller then skips normalize and falls
// back to the plain user gain. Decodes to the SAME 48 kHz stereo int16 PCM
// the main pass scales, so the measured peak matches what gets scaled.
double MeasureSourceAudioPeak(const std::wstring& source_path,
                              const std::function<bool()>& is_cancelled) {
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(source_path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return 0.0;
  }
  DWORD video_index = kNoStream;
  DWORD audio_index = kNoStream;
  IdentifyStreams(reader.Get(), &video_index, &audio_index);
  if (audio_index == kNoStream) {
    return 0.0;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(audio_index, TRUE);

  ComPtr<IMFMediaType> pcm_type;
  if (FAILED(::MFCreateMediaType(pcm_type.GetAddressOf()))) {
    return 0.0;
  }
  pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  if (FAILED(reader->SetCurrentMediaType(audio_index, nullptr,
                                         pcm_type.Get()))) {
    return 0.0;
  }

  double peak = 0.0;
  for (;;) {
    // Honor cancel during the (whole-track) loudness scan; the main loop's
    // cancel check then aborts the export. Returning the peak-so-far is fine
    // since a cancel discards the export.
    if (is_cancelled && is_cancelled()) {
      break;
    }
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &timestamp,
                                  sample.GetAddressOf()))) {
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) ||
        buffer == nullptr) {
      continue;
    }
    BYTE* data = nullptr;
    DWORD max_len = 0;
    DWORD cur_len = 0;
    if (SUCCEEDED(buffer->Lock(&data, &max_len, &cur_len)) && data != nullptr &&
        cur_len > 0) {
      const std::size_t n = cur_len / sizeof(std::int16_t);
      const double buffer_peak =
          Int16PeakLinear(reinterpret_cast<const std::int16_t*>(data), n);
      if (buffer_peak > peak) {
        peak = buffer_peak;
      }
    }
    if (data != nullptr) {
      buffer->Unlock();
    }
  }
  return peak;
}

}  // namespace

bool IsDiskFullHresult(HRESULT hr) {
  return hr == HRESULT_FROM_WIN32(ERROR_DISK_FULL) ||
         hr == HRESULT_FROM_WIN32(ERROR_HANDLE_DISK_FULL);
}

bool IsDeviceRemovedHresult(HRESULT hr) {
  return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET ||
         hr == DXGI_ERROR_DEVICE_HUNG ||
         hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR ||
         hr == D2DERR_RECREATE_TARGET;
}

RenderResult RenderComposedExport(const RenderRequest& request) {
  EnsureMediaFoundationStarted();

  // PARITY GAP (macOS has this, Windows does not yet): there is no pre-flight
  // of `request.destination_path` before the expensive work below. macOS added
  // one in `ExportEngine.destinationProblem` after a real report — exporting to
  // a remembered folder on a disk that had been ejected rendered the full
  // 31-second screen pre-pass and only failed when the writer finally tried to
  // create the output, surfacing as a bare "Cannot create file".
  //
  // Windows is exposed to the same thing, and arguably more: the save folder is
  // remembered as a plain path string, so a mapped network drive that is no
  // longer connected, an ejected USB volume, or a drive letter that has since
  // changed all look valid in the export dialog and only fail at the Sink
  // Writer, after the whole render.
  //
  // The fix mirrors macOS: right here, before `D3DDevice::Create`, check that
  // the destination's parent directory exists, is a directory, and is actually
  // writable (probe-write a temp file rather than trusting an attribute — a
  // network share can report writable and still refuse), and return
  // `Failure(...)` with a message that names the cause. Distinguish "the disk
  // or share is not connected" from "the folder is gone": telling someone their
  // folder no longer exists sends them looking for something that is really
  // just unplugged. See macos/Runner/Capture/Export/ExportEngine.swift and
  // macos/RunnerTests/ExportDestinationPreflightTests.swift.

  // Slice 5A: bail before any heavy GPU/MF setup if already cancelled. No
  // output file exists yet, so Cancelled() just returns the clean result.
  if (request.is_cancelled && request.is_cancelled()) {
    return Cancelled(request.destination_path);
  }

  // Slice 5B: a .gif destination is encoded with the WIC GIF encoder instead of
  // the H.264 Sink Writer. GIF carries no audio and the frame loop decimates to
  // ~kGifTargetFps; everything else (decode, Direct2D composition, progress,
  // cancel) is shared with the video path.
  const bool gif = IsGifDestination(request.destination_path);

  // --- D3D11 device shared by decode-upload, Direct2D, and the encoder.
  clingfy::graphics::D3DDevice device;
  if (auto err = device.Create()) {
    return Failure(request.destination_path, "export: D3D11 device creation failed — " + err->message);
  }
  // Standby-resume recovery: classify a failure as device loss either by
  // its own HRESULT or by the device's removed-reason — a dead device makes
  // UNRELATED calls fail with generic codes (E_FAIL, MF errors), so the
  // probe catches losses the failing HRESULT alone would miss. The router
  // retries the whole export once on a fresh device when a failure carries
  // this classification.
  const auto device_lost = [&device](HRESULT hr) {
    return IsDeviceRemovedHresult(hr) ||
           (device.device() != nullptr &&
            device.device()->GetDeviceRemovedReason() != S_OK);
  };

  // The hardware H.264 MFT runs the encode on its own worker thread, so
  // the device it shares with our Direct2D draws must be multithread
  // protected. Best-effort: older feature levels may not expose the
  // interface, in which case the software path still works.
  {
    ComPtr<ID3D11Multithread> multithread;
    if (SUCCEEDED(device.context()->QueryInterface(
            IID_PPV_ARGS(multithread.GetAddressOf()))) &&
        multithread != nullptr) {
      multithread->SetMultithreadProtected(TRUE);
    }
  }

  // --- Source reader: decode video to BGRA system memory + audio to PCM.
  ComPtr<IMFAttributes> reader_attrs;
  if (FAILED(::MFCreateAttributes(reader_attrs.GetAddressOf(), 1))) {
    return Failure(request.destination_path, "export: MFCreateAttributes failed for the source reader.");
  }
  reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  ComPtr<IMFSourceReader> reader;
  HRESULT hr = ::MFCreateSourceReaderFromURL(request.source_video_path.c_str(),
                                             reader_attrs.Get(),
                                             reader.GetAddressOf());
  if (FAILED(hr) || reader == nullptr) {
    return Failure(request.destination_path, Hr("export: MFCreateSourceReaderFromURL failed — the "
                      "recording may be missing or unreadable",
                      hr));
  }

  DWORD video_index = kNoStream;
  DWORD audio_index = kNoStream;
  IdentifyStreams(reader.Get(), &video_index, &audio_index);
  if (video_index == kNoStream) {
    return Failure(request.destination_path, "export: source has no decodable video stream.");
  }
  reader->SetStreamSelection(video_index, TRUE);

  // Force the video stream to BGRA (ARGB32 in MF terms). The reader
  // inserts a video processor to convert from NV12/etc.
  {
    ComPtr<IMFMediaType> rgb_type;
    if (FAILED(::MFCreateMediaType(rgb_type.GetAddressOf()))) {
      return Failure(request.destination_path, "export: MFCreateMediaType failed for the RGB32 output.");
    }
    rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    hr = reader->SetCurrentMediaType(video_index, nullptr, rgb_type.Get());
    if (FAILED(hr)) {
      return Failure(request.destination_path, Hr("export: could not configure RGB32 video decode", hr));
    }
  }

  // Read the true source dimensions from the negotiated type rather than
  // trusting the project metadata.
  UINT32 source_w = 0;
  UINT32 source_h = 0;
  {
    ComPtr<IMFMediaType> current;
    if (FAILED(reader->GetCurrentMediaType(video_index, current.GetAddressOf())) ||
        FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &source_w,
                                    &source_h)) ||
        source_w == 0 || source_h == 0) {
      return Failure(request.destination_path, "export: could not determine source video dimensions.");
    }
  }

  // Total duration (HNS) for the progress fraction. Best-effort: some
  // containers don't report it, in which case progress stays indeterminate
  // (no per-frame fraction emitted) but a terminal 1.0 still fires on success.
  LONGLONG duration_hns = 0;
  {
    PROPVARIANT duration_var;
    PropVariantInit(&duration_var);
    if (SUCCEEDED(reader->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
            &duration_var)) &&
        duration_var.vt == VT_UI8) {
      duration_hns = static_cast<LONGLONG>(duration_var.uhVal.QuadPart);
    }
    PropVariantClear(&duration_var);
  }

  // Audio separation (D8): when export_passthrough probed a decodable
  // sidecar, the separated tracks REPLACE the embedded premix — the main
  // reader's audio stream is never selected and audio runs through the
  // per-track pumps built below (macOS parity: separated sources supersede
  // the embedded track; the premix stays only as the no-sidecar fallback).
  const bool separated_audio =
      !gif && (!request.mic_audio_path.empty() ||
               !request.system_audio_path.empty());

  // Audio is optional. Try to pull it through as 48 kHz stereo int16 PCM;
  // if the source has no audio or the type is refused, fall back to a
  // video-only export rather than failing the whole render.
  // GIF has no audio track, so skip audio selection/decode entirely for it.
  bool has_audio = false;
  if (!gif && !separated_audio && audio_index != kNoStream) {
    reader->SetStreamSelection(audio_index, TRUE);
    ComPtr<IMFMediaType> pcm_type;
    if (SUCCEEDED(::MFCreateMediaType(pcm_type.GetAddressOf()))) {
      pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                          static_cast<UINT32>(kExportAudioSampleRate));
      pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kExportAudioChannels);
      if (SUCCEEDED(reader->SetCurrentMediaType(audio_index, nullptr,
                                                pcm_type.Get()))) {
        has_audio = true;
      } else {
        reader->SetStreamSelection(audio_index, FALSE);
      }
    }
  }

  // --- Slice 4 audio level: resolve the single gain/volume/normalize
  // multiplier applied to every decoded PCM sample. Normalize needs the
  // whole-track peak, so it runs a separate audio-only decode pass first
  // (matches macOS, which measures via its own reader). Loop-invariant.
  double audio_peak = 0.0;
  if (has_audio && request.auto_normalize) {
    audio_peak =
        MeasureSourceAudioPeak(request.source_video_path, request.is_cancelled);
  }
  const AudioGainStages audio_stages = ResolveAudioGainStages(
      request.audio_gain_db, request.audio_volume_percent,
      request.auto_normalize, request.target_loudness_dbfs, audio_peak);

  // Audio separation (D8): per-track stages. Normalize measures the MIC
  // sidecar's peak (never the premix, never system audio) and only when a
  // mic sidecar exists — with no decodable mic, gain/normalize are inert by
  // construction and only the master volume (system stage) applies.
  double mic_peak = 0.0;
  if (separated_audio && request.auto_normalize &&
      !request.mic_audio_path.empty()) {
    mic_peak =
        MeasureSourceAudioPeak(request.mic_audio_path, request.is_cancelled);
  }
  const SeparatedAudioStages separated_stages = ResolveSeparatedAudioStages(
      request.audio_gain_db, request.audio_volume_percent,
      request.auto_normalize, request.target_loudness_dbfs, mic_peak);

  // --- Geometry: output size + source placement, via the tested helpers.
  const SizeF source_size{static_cast<double>(source_w),
                          static_cast<double>(source_h)};
  const PixelSize canvas =
      ToEvenPixelSize(ResolveTargetSize(source_size, request.layout,
                                        request.resolution));
  const RectF content = ComputeContentRect(
      SizeF{static_cast<double>(canvas.width),
            static_cast<double>(canvas.height)},
      source_size, ParseFitMode(request.fit), request.padding);

  // --- Direct2D device + context on the shared D3D11 device.
  ComPtr<ID2D1Factory1> d2d_factory;
  {
    D2D1_FACTORY_OPTIONS options{};
    hr = ::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                             __uuidof(ID2D1Factory1), &options,
                             reinterpret_cast<void**>(d2d_factory.GetAddressOf()));
    if (FAILED(hr) || d2d_factory == nullptr) {
      return Failure(request.destination_path, Hr("export: D2D1CreateFactory failed", hr));
    }
  }
  ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(device.device()->QueryInterface(IID_PPV_ARGS(dxgi_device.GetAddressOf())))) {
    return Failure(request.destination_path, "export: ID3D11Device has no IDXGIDevice (BGRA support "
                   "flag missing?).");
  }
  ComPtr<ID2D1Device> d2d_device;
  if (const HRESULT d2d_hr = d2d_factory->CreateDevice(
          dxgi_device.Get(), d2d_device.GetAddressOf());
      FAILED(d2d_hr)) {
    return Failure(request.destination_path,
                   "export: ID2D1Factory1::CreateDevice failed.",
                   /*disk_full=*/false, device_lost(d2d_hr));
  }
  ComPtr<ID2D1DeviceContext> d2d_ctx;
  if (const HRESULT ctx_hr = d2d_device->CreateDeviceContext(
          D2D1_DEVICE_CONTEXT_OPTIONS_NONE, d2d_ctx.GetAddressOf());
      FAILED(ctx_hr)) {
    return Failure(request.destination_path,
                   "export: ID2D1Device::CreateDeviceContext failed.",
                   /*disk_full=*/false, device_lost(ctx_hr));
  }

  // Phase 8.2: optional cursor renderer. Draws the sidecar cursor on top of the
  // composited video each frame. Soft-fail at every step — a missing / malformed
  // sidecar or a geometry/brush failure simply renders no cursor; the export
  // never fails because of the cursor.
  std::unique_ptr<CursorExportRenderer> cursor_renderer;
  if (request.show_cursor && !request.cursor_sidecar_path.empty()) {
    cursor_renderer = CursorExportRenderer::Create(request.cursor_sidecar_path);
    if (cursor_renderer != nullptr &&
        !cursor_renderer->Prepare(d2d_factory.Get(), d2d_ctx.Get())) {
      cursor_renderer.reset();
    }
  }

  // Phase 8.3: optional smart-zoom controller. Builds auto-zoom segments from the
  // sidecar (clicks + cursor) and produces a smoothed per-frame transform. Same
  // soft-fail discipline as the cursor renderer — null → no zoom.
  std::unique_ptr<ZoomExportController> zoom_controller;
  if (request.zoom_enabled && !request.cursor_sidecar_path.empty()) {
    zoom_controller = ZoomExportController::Create(
        request.cursor_sidecar_path, duration_hns / 10000, request.zoom_factor);
  }

  // Phase 9.4: optional camera bubble. Opens camera/raw.mov on its own reader
  // and draws a masked bubble on top of the composite in canvas space (NOT under
  // the smart-zoom transform). Soft-fail: Create/Prepare returning null/false
  // simply renders no camera and the export proceeds screen-only. The bubble
  // rect is resolved once from the (loop-invariant) canvas + Dart geometry args.
  std::unique_ptr<CameraExportRenderer> camera_renderer;
  if (request.draw_camera && !request.camera_video_path.empty()) {
    camera_renderer = CameraExportRenderer::Create(
        request.camera_video_path, request.camera_start_offset_ms);
    if (camera_renderer != nullptr) {
      const CameraBubbleRect bubble = ComputeCameraBubbleRect(
          static_cast<double>(canvas.width), static_cast<double>(canvas.height),
          request.camera_has_center, request.camera_center_x,
          request.camera_center_y, request.camera_layout_preset,
          request.camera_size_factor);
      CameraExportRenderer::Style cam_style;
      cam_style.mirror = request.camera_mirror;
      cam_style.opacity = request.camera_opacity;
      cam_style.border_width = request.camera_border_width;
      cam_style.has_border_color = request.camera_border_color_argb.has_value();
      cam_style.border_argb = static_cast<std::uint32_t>(
          request.camera_border_color_argb.value_or(0));
      cam_style.shadow_preset = request.camera_shadow_preset;
      // Phase 9.7 chroma key.
      cam_style.chroma_enabled = request.camera_chroma_enabled;
      cam_style.chroma_strength = request.camera_chroma_strength;
      cam_style.has_chroma_color =
          request.camera_chroma_color_argb.has_value();
      cam_style.chroma_argb = static_cast<std::uint32_t>(
          request.camera_chroma_color_argb.value_or(0));
      // Phase 9.7 intro/outro animation. Edge resolved once from the (loop-
      // invariant) placement; unknown presets parse to kNone (static bubble).
      CameraAnimationParams cam_anim;
      cam_anim.intro = ParseCameraIntroKind(request.camera_intro_preset);
      cam_anim.outro = ParseCameraOutroKind(request.camera_outro_preset);
      cam_anim.intro_duration_ms = request.camera_intro_duration_ms;
      cam_anim.outro_duration_ms = request.camera_outro_duration_ms;
      const CameraSlideEdge cam_edge = ResolveCameraSlideEdge(
          request.camera_layout_preset, request.camera_has_center, bubble,
          static_cast<double>(canvas.width),
          static_cast<double>(canvas.height));
      if (!camera_renderer->Prepare(
              d2d_factory.Get(), d2d_ctx.Get(), bubble, request.camera_shape,
              request.camera_corner_radius, request.camera_content_mode,
              cam_style, cam_anim, static_cast<double>(canvas.width),
              static_cast<double>(canvas.height), cam_edge,
              request.camera_zoom_behavior,
              request.camera_zoom_scale_multiplier,
              request.camera_layout_preset)) {
        camera_renderer.reset();
      }
    }
  }

  // Reusable source bitmap: a fresh decoded frame is uploaded into it via
  // CopyFromMemory each iteration. Sized to the source; the fit/fill
  // scale happens in the DrawBitmap dest rect, not here.
  ComPtr<ID2D1Bitmap1> source_bitmap;
  {
    const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
    if (const HRESULT bmp_hr =
            d2d_ctx->CreateBitmap(D2D1::SizeU(source_w, source_h), nullptr, 0,
                                  &props, source_bitmap.GetAddressOf());
        FAILED(bmp_hr)) {
      return Failure(request.destination_path,
                     "export: ID2D1DeviceContext::CreateBitmap failed for the "
                     "source frame.",
                     /*disk_full=*/false, device_lost(bmp_hr));
    }
  }

  // --- Editing port (color): the graded-content pass -------------------------
  //
  // When the grade is non-identity, the content that macOS grades — the
  // screen video + cursor + click ripples, NOT the background or camera —
  // is drawn into a canvas-sized FLOAT16 intermediate instead of the output
  // target, then run through:
  //
  //     content(16F, sRGB-encoded, premultiplied)
  //        └─► ColorManagement  sRGB → scRGB      (piecewise linearization —
  //        │                                       D2D has no sRGB-transfer
  //        │                                       primitive; GammaTransfer is
  //        │                                       a pure power curve)
  //        └─► ColorMatrix      BuildColorMatrix   (straight alpha, the one
  //        │                    (grade), 5x4       matrix replicating the
  //        │                                       whole macOS filter chain)
  //        └─► ColorManagement  scRGB → sRGB       (re-encode)
  //        └─► DrawImage onto the output target (canvas-sized: no scaling),
  //            then the camera draws on top, ungraded.
  //
  // Every effect runs at 16bpc float (8bpc intermediates band the shadows).
  // Failure posture (decision 2A, macOS parity): if any of this cannot be
  // built, the export continues UNGRADED with a loud diagnostic log — same
  // best-effort semantics as a CIFilter returning nil on macOS.
  const bool wants_grade = !request.color_grade.IsIdentity();
  bool grading = false;
  ComPtr<ID2D1Bitmap1> content_bitmap;
  clingfy::graphics::ColorGradeEffectChain grade_chain;
  if (wants_grade) {
    const auto fail_grade = [&](const char* step, HRESULT fail_hr) {
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Export",
          "EXPORT_COLOR_GRADE_DEGRADED: could not build the color-grade "
          "pass — " +
              Hr(step, fail_hr) +
              " — exporting UNGRADED (macOS-parity best-effort).");
      content_bitmap.Reset();
      grade_chain.Reset();
    };

    const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET,
        D2D1::PixelFormat(DXGI_FORMAT_R16G16B16A16_FLOAT,
                          D2D1_ALPHA_MODE_PREMULTIPLIED));
    HRESULT grade_hr = d2d_ctx->CreateBitmap(
        D2D1::SizeU(canvas.width, canvas.height), nullptr, 0, &props,
        content_bitmap.GetAddressOf());
    if (FAILED(grade_hr)) {
      fail_grade("content bitmap", grade_hr);
    } else if (FAILED(grade_hr = grade_chain.Build(d2d_ctx.Get(),
                                                   request.color_grade))) {
      fail_grade("effect chain", grade_hr);
    } else {
      grade_chain.SetInput(content_bitmap.Get());
      grading = true;
    }
  }

  // --- Output encoder at the target resolution. A .gif destination uses the
  // WIC GIF encoder (Slice 5B); otherwise the H.264 Sink Writer, whose
  // container (.mp4 vs .mov) is chosen by the destination_path extension and
  // whose bitrate comes from the Slice 5A preset (ignored by GIF, which is
  // palette-indexed). Both encoders are declared; only the selected one is
  // opened, and the lambdas below route every frame-loop call to it so the
  // loop stays single-path.
  clingfy::encoding::MfSinkWriterEncoder encoder;
  clingfy::encoding::GifEncoder gif_encoder;
  if (gif) {
    clingfy::encoding::EncoderConfig gif_config;
    gif_config.output_path = request.destination_path;
    gif_config.width = canvas.width;
    gif_config.height = canvas.height;
    if (auto err = gif_encoder.Open(gif_config, device)) {
      return Failure(request.destination_path,
                     "export: GIF encoder open failed — " + err->message,
                     IsDiskFullHresult(err->hr), device_lost(err->hr));
    }
  } else {
    clingfy::encoding::EncoderConfig enc_config;
    enc_config.output_path = request.destination_path;
    enc_config.width = canvas.width;
    enc_config.height = canvas.height;
    enc_config.fps = request.fps_hint != 0 ? request.fps_hint : 30u;
    enc_config.avg_bitrate_bps = ResolveVideoBitrateBps(
        request.bitrate, canvas.width, canvas.height, enc_config.fps);

    std::optional<clingfy::encoding::AudioEncoderConfig> audio_config;
    // Separated recordings feed the encoder from the sidecar pumps, not the
    // (deselected) embedded stream — the output still needs its AAC track.
    if (has_audio || separated_audio) {
      audio_config = clingfy::encoding::AudioEncoderConfig{};
    }
    if (auto err = encoder.Open(enc_config, device, audio_config)) {
      // The sink writer binds MF_SINK_WRITER_D3D_MANAGER to this device, so
      // hardware-MFT activation is a common first-failure site after a
      // device loss.
      return Failure(request.destination_path,
                     "export: encoder open failed — " + err->message,
                     IsDiskFullHresult(err->hr), device_lost(err->hr));
    }
  }

  auto write_video_frame =
      [&](const clingfy::capture::CapturedVideoFrame& f)
      -> std::optional<clingfy::encoding::EncoderError> {
    return gif ? gif_encoder.WriteVideoFrame(f) : encoder.WriteVideoFrame(f);
  };
  auto cancel_encoder = [&]() {
    if (gif) {
      gif_encoder.Cancel();
    } else {
      encoder.Cancel();
    }
  };
  auto finalize_encoder =
      [&]() -> std::optional<clingfy::encoding::EncoderError> {
    return gif ? gif_encoder.Finalize() : encoder.Finalize();
  };

  // --- Frame loop: pull samples interleaved by timestamp.
  std::vector<BYTE> top_down;  // reused per video frame
  const D2D1_RECT_F dest_rect = D2D1::RectF(
      static_cast<float>(content.x), static_cast<float>(content.y),
      static_cast<float>(content.x + content.width),
      static_cast<float>(content.y + content.height));

  // --- Slice 3 canvas styling. All loop-invariant (it depends only on the
  // canvas / content rect / args, none of which change per frame), so the
  // color, clamped radius, and the rounded-clip geometry + layer are
  // resolved/built once here.
  const RgbaColor bg = ResolveBackgroundColor(request.background_color);
  // GIF has no partial alpha, and the composited texture is premultiplied —
  // feeding a translucent background through the WIC straight-alpha path would
  // darken padding margins / anti-aliased corners. Force the GIF background
  // fully opaque so those regions show the solid background color instead.
  const D2D1_COLOR_F clear_color =
      D2D1::ColorF(static_cast<float>(bg.r), static_cast<float>(bg.g),
                   static_cast<float>(bg.b),
                   gif ? 1.0f : static_cast<float>(bg.a));
  // Background image, decoded ONCE for the whole export (loop-invariant, like
  // the fill and the clip above). The same cache the preview uses, so both
  // consumers resolve the file identically.
  background::BackgroundImageCache export_bg_cache;
  background::PresetBitmapCache export_preset_cache;
  // A preset outranks an image (the UI offers one kind at a time). Both become
  // a bitmap drawn to cover, so they share the draw below. Rendered ONCE for
  // the whole export, like the fill and the clip.
  ID2D1Bitmap* export_bg_image = nullptr;
  if (request.has_background_preset) {
    export_bg_image = export_preset_cache.Get(
        d2d_ctx.Get(), request.background_preset,
        static_cast<UINT>(canvas.width), static_cast<UINT>(canvas.height));
  } else {
    export_bg_image =
        export_bg_cache.Get(d2d_ctx.Get(), request.background_image_path);
  }

  const double corner_radius_px =
      ResolveCornerRadiusPx(request.corner_radius, content);
  ComPtr<ID2D1RoundedRectangleGeometry> rounded_clip;
  ComPtr<ID2D1Layer> rounded_layer;
  if (corner_radius_px > 0.0) {
    // Best-effort: if the geometry or layer can't be created, fall back to
    // square corners rather than failing the whole export.
    if (FAILED(d2d_factory->CreateRoundedRectangleGeometry(
            D2D1::RoundedRect(dest_rect,
                              static_cast<float>(corner_radius_px),
                              static_cast<float>(corner_radius_px)),
            rounded_clip.GetAddressOf())) ||
        FAILED(d2d_ctx->CreateLayer(nullptr, rounded_layer.GetAddressOf()))) {
      rounded_clip.Reset();
      rounded_layer.Reset();
    }
  }

  std::uint64_t video_frames = 0;
  std::uint64_t audio_packets = 0;
  // Phase 8.2: rebase cursor lookups to the first decoded video frame, so the
  // sidecar's recording-relative tMs lines up with the file's PTS regardless of
  // the container's absolute PTS base.
  std::int64_t first_video_hns = -1;
  // Phase 8.3: previous KEPT video frame's PTS, for the smoother's dt.
  std::int64_t prev_frame_hns = -1;
  bool video_eos = false;
  bool audio_eos = !has_audio;  // nothing to drain when there is no audio
  double last_progress_emitted = -1.0;  // Slice 5A: throttle progress ticks

  // Editing port (clips): keep/drop + re-stamp state. Empty ranges leave every
  // value at its identity so the loop is byte-identical to the pre-clip path.
  // MONOTONIC ranges forward-read here; REORDER/OVERLAP take the per-range
  // backward-seek branch below. `origin_edited_hns` is the first KEPT video
  // frame's
  // edited PTS — the common zero both streams rebase onto: the encoder rebases
  // VIDEO by its first written frame but writes AUDIO raw, so audio is shifted
  // by this same origin here to keep A/V aligned on a head-trim (outside-voice
  // #1). `pending_audio` buffers the ≤~2 kept audio packets that can arrive
  // between the first kept range's start and the first kept video frame, so no
  // audio is lost and none is written before the timeline is anchored (#2).
  const bool clipping = !request.clip_ranges.empty();
  const std::int64_t edited_total_ms =
      clipping ? clip_planner::EditedDurationMs(request.clip_ranges) : 0;
  const std::uint32_t fps_fallback =
      request.fps_hint != 0 ? request.fps_hint : 30u;
  std::int64_t origin_edited_hns = -1;
  std::int64_t prev_edited_ms = -1;  // previous KEPT frame's edited ms (zoom dt)
  std::vector<clingfy::audio::MixedPacket> pending_audio;

  // Slice 5B GIF decimation: a running emit target on an ideal grid (see
  // gif_export_policy.h). Seeded so the first decoded frame is always kept; a
  // 30/60 fps source becomes a ~kGifTargetFps GIF, jitter-tolerant.
  std::int64_t gif_emit_target_hns = kGifEmitTargetStart;

  // Slice 5A: emit a 0..1 progress fraction from the video PTS, throttled to
  // ~1% steps so a long clip doesn't flood the channel. Indeterminate (no emit)
  // when the source reported no duration. Shared by the kept- and (GIF-)dropped-
  // frame paths so the bar advances per decoded frame regardless of decimation.
  auto report_progress_frac = [&](double frac) {
    if (!request.on_progress) {
      return;
    }
    frac = frac < 0.0 ? 0.0 : (frac > 1.0 ? 1.0 : frac);
    if (frac >= last_progress_emitted + 0.01) {
      last_progress_emitted = frac;
      request.on_progress(frac);
    }
  };
  auto emit_progress = [&](LONGLONG ts) {
    if (duration_hns > 0) {
      report_progress_frac(static_cast<double>(ts) /
                           static_cast<double>(duration_hns));
    }
  };

  // Editing port (clips, 3b-2a): reorder / non-monotonic export. When the kept
  // ranges are not source-monotonic, a single forward read cannot emit them in
  // timeline order — the output PTS would go backward (§5.3). Instead we read
  // each range's source window in TIMELINE order, seeking the reader BACKWARD as
  // needed; kept frames re-stamp onto a contiguous edited timeline and the
  // source-keyed effects (zoom smoother, camera reader) reset at each boundary
  // (§5.4/§5.5). Audio (3b-2b) rides a SEPARATE reader — the reorder-audio pump —
  // because the backward per-range seeks would corrupt this reader's forward
  // audio decode; here the main reader's audio stream is deselected and audio is
  // drained by the pump, interleaved with the video writes below.
  const bool reorder =
      clipping && !clip_planner::IsSourceMonotonic(request.clip_ranges);
  const int reorder_n = static_cast<int>(request.clip_ranges.size());
  int reorder_range_idx = 0;
  std::int64_t reorder_edited_base_ms = 0;
  std::unique_ptr<ReorderAudioPump> reorder_audio_pump;
  if (reorder) {
    // frame_ms must stay container-relative (0-based) to match clip_ranges, so
    // anchor to source 0 rather than the first post-seek frame (which sits at
    // range 0's window, not source 0). The recorder writes from PTS 0.
    first_video_hns = 0;
    if (has_audio) {
      reader->SetStreamSelection(audio_index, FALSE);
      // Build the decoupled audio pass from the edited-timeline audio slots.
      // audio_duration_ms clamps each slot's copied length to the captured
      // audio extent; the source presentation duration is an upper bound (audio
      // can run shorter than video), and the pump's own EOS→silence handling
      // fills any further shortfall, so the exact bound is not load-bearing.
      const std::int64_t audio_duration_ms =
          duration_hns > 0 ? duration_hns / 10000 : edited_total_ms;
      const auto audio_slots =
          clip_planner::AudioSlots(request.clip_ranges, audio_duration_ms);
      reorder_audio_pump = ReorderAudioPump::Create(
          request.source_video_path, audio_slots, kExportAudioSampleRate,
          kExportAudioChannels, audio_stages);
    }
    // The main reader is video-only under reorder; audio is the pump's job.
    audio_eos = true;
    SeekSourceReader(reader.Get(), request.clip_ranges[0].source_in_ms);
    if (zoom_controller != nullptr) {
      zoom_controller->ResetSmoothing();
    }
    if (camera_renderer != nullptr) {
      camera_renderer->SeekTo(request.clip_ranges[0].source_in_ms);
    }
  }

  // Audio separation (D8): one pump per decodable sidecar over ONE shared
  // slots plan (clip-built when clipping, a single whole-track slot
  // otherwise), mixed down through SeparatedAudioMerge to the encoder's
  // single AAC track. Both pumps run the same plan so their totals agree at
  // every limit; the merge FIFOs absorb per-packet boundary skew. Soft-fail
  // discipline matches the reorder pump: a pump that can't be built drops
  // that track (probe passed, so this is rare); both failing → video-only.
  std::unique_ptr<ReorderAudioPump> sep_mic_pump;
  std::unique_ptr<ReorderAudioPump> sep_system_pump;
  std::optional<SeparatedAudioMerge> sep_merge;
  std::int64_t sep_emitted_frames = 0;
  if (separated_audio) {
    const std::int64_t audio_duration_ms =
        duration_hns > 0 ? duration_hns / 10000 : edited_total_ms;
    std::vector<clip_planner::AudioSlot> slots;
    if (clipping) {
      slots = clip_planner::AudioSlots(request.clip_ranges, audio_duration_ms);
    } else if (audio_duration_ms > 0) {
      // Identity plan: the whole recording as one slot — the pump's copy +
      // EOS→silence handling reproduces the track end-to-end. A source with
      // no reported duration (audio_duration_ms 0) builds no plan: a slot
      // with an unbounded duration would silence-fill forever at Flush.
      clip_planner::AudioSlot whole;
      whole.source_in_ms = 0;
      whole.edited_start_ms = 0;
      whole.copy_duration_ms = audio_duration_ms;
      whole.duration_ms = audio_duration_ms;
      slots.push_back(whole);
    }
    if (!slots.empty()) {
      if (!request.mic_audio_path.empty()) {
        sep_mic_pump = ReorderAudioPump::Create(
            request.mic_audio_path, slots, kExportAudioSampleRate,
            kExportAudioChannels, separated_stages.mic);
      }
      if (!request.system_audio_path.empty()) {
        sep_system_pump = ReorderAudioPump::Create(
            request.system_audio_path, slots, kExportAudioSampleRate,
            kExportAudioChannels, separated_stages.system);
      }
    }
    if (sep_mic_pump != nullptr || sep_system_pump != nullptr) {
      sep_merge.emplace(sep_mic_pump != nullptr, sep_system_pump != nullptr,
                        kExportAudioChannels);
    }
  }
  // Pump both tracks to `limit_frames`, then write every merge-ready frame
  // as summed packets timestamped by the running emitted-frame counter,
  // origin-shifted like the reorder pump's export sink.
  const auto drain_separated =
      [&](std::int64_t limit_frames, std::int64_t origin_hns)
      -> std::optional<clingfy::encoding::EncoderError> {
    if (sep_mic_pump != nullptr) {
      if (auto err = sep_mic_pump->PumpUpTo(
              limit_frames,
              [&](clingfy::audio::MixedPacket&& p, std::int64_t)
                  -> std::optional<clingfy::encoding::EncoderError> {
                sep_merge->AppendMic(p.samples.data(), p.frame_count);
                return std::nullopt;
              })) {
        return err;
      }
    }
    if (sep_system_pump != nullptr) {
      if (auto err = sep_system_pump->PumpUpTo(
              limit_frames,
              [&](clingfy::audio::MixedPacket&& p, std::int64_t)
                  -> std::optional<clingfy::encoding::EncoderError> {
                sep_merge->AppendSystem(p.samples.data(), p.frame_count);
                return std::nullopt;
              })) {
        return err;
      }
    }
    // ~85 ms packets: comfortably small allocations, few writer calls.
    constexpr std::int64_t kMergePacketFrames = 4096;
    std::vector<std::int16_t> merged;
    while (sep_merge->ReadyFrames() > 0) {
      const std::int64_t frames = sep_merge->PopMerged(kMergePacketFrames,
                                                       merged);
      if (frames == 0) {
        break;
      }
      clingfy::audio::MixedPacket packet;
      packet.samples = std::move(merged);
      packet.frame_count = static_cast<std::uint32_t>(frames);
      packet.timestamp_hns = std::max<std::int64_t>(
          0, (sep_emitted_frames * 10'000'000) / kExportAudioSampleRate -
                 origin_hns);
      sep_emitted_frames += frames;
      if (auto err = encoder.WriteAudioPacket(packet)) {
        return err;
      }
      ++audio_packets;
      merged = std::move(packet.samples);  // reuse the allocation
    }
    return std::nullopt;
  };

  while (!(video_eos && audio_eos)) {
    // Slice 5A: cancel between samples — release the writer without
    // finalizing and delete the partial file, then reply cleanly.
    if (request.is_cancelled && request.is_cancelled()) {
      cancel_encoder();
      return Cancelled(request.destination_path);
    }
    DWORD actual_index = 0;
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0,
                            &actual_index, &flags, &timestamp,
                            sample.GetAddressOf());
    if (FAILED(hr)) {
      cancel_encoder();
      return Failure(request.destination_path,
                     Hr("export: IMFSourceReader::ReadSample failed", hr),
                     /*disk_full=*/false, device_lost(hr));
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      if (actual_index == video_index) {
        if (reorder && reorder_range_idx + 1 < reorder_n) {
          // A kept range ended exactly at source EOS; advance to the next
          // timeline range and seek (backward) rather than ending the export.
          reorder_edited_base_ms +=
              request.clip_ranges[reorder_range_idx].DurationMs();
          ++reorder_range_idx;
          const std::int64_t next_in =
              request.clip_ranges[reorder_range_idx].source_in_ms;
          SeekSourceReader(reader.Get(), next_in);
          if (zoom_controller != nullptr) {
            zoom_controller->ResetSmoothing();
          }
          if (camera_renderer != nullptr) {
            camera_renderer->SeekTo(next_in);
          }
          continue;
        }
        video_eos = true;
      } else if (actual_index == audio_index) {
        audio_eos = true;
      }
    }
    if (sample == nullptr) {
      continue;
    }

    if (actual_index == video_index) {
      // Anchor the cursor-time rebase to the first decoded video frame (before
      // any GIF decimation) so it tracks the true start of the timeline.
      if (first_video_hns < 0) {
        first_video_hns = timestamp;
      }
      // The frame's recording-relative ms (rebased to the first decoded frame),
      // truncated (§5.1) — shared by the clip gate, cursor, zoom, and camera.
      const std::int64_t frame_ms =
          first_video_hns >= 0 ? (timestamp - first_video_hns) / 10000 : 0;
      // Editing port (clips, 3a): keep/drop this source frame against the edited
      // timeline BEFORE any decode-upload / camera / texture work. nullopt => the
      // frame is inside a cut gap: drop it (still advance progress so the bar
      // tracks decode position). Empty ranges => identity (never nullopt).
      std::optional<std::int64_t> edited;
      if (reorder) {
        // Per-range window gate, in timeline order. Past the current range's end
        // → advance + seek (re-priming the source-keyed effects) to the next
        // range, then discard this boundary frame and re-read from the new
        // position. Before the range's start → keyframe lead-in, discard.
        if (reorder_range_idx >= reorder_n) {
          video_eos = true;
          continue;
        }
        const auto& r = request.clip_ranges[reorder_range_idx];
        if (frame_ms >= r.source_out_ms) {
          reorder_edited_base_ms += r.DurationMs();
          ++reorder_range_idx;
          if (reorder_range_idx < reorder_n) {
            const std::int64_t next_in =
                request.clip_ranges[reorder_range_idx].source_in_ms;
            SeekSourceReader(reader.Get(), next_in);
            if (zoom_controller != nullptr) {
              zoom_controller->ResetSmoothing();
            }
            if (camera_renderer != nullptr) {
              camera_renderer->SeekTo(next_in);
            }
          } else {
            video_eos = true;  // all kept ranges emitted
          }
          continue;
        }
        if (frame_ms < r.source_in_ms) {
          continue;  // keyframe lead-in before the range window
        }
        edited = reorder_edited_base_ms + (frame_ms - r.source_in_ms);
      } else if (clipping) {
        edited =
            clip_planner::EditedMsForKeptSourceMs(frame_ms, request.clip_ranges);
        if (!edited.has_value()) {
          emit_progress(timestamp);
          continue;
        }
      }
      // Slice 5B: drop frames that fall inside the target GIF interval before
      // any composite/encode work; still advance progress for the dropped
      // frame so the bar tracks decode position. Non-GIF keeps every frame.
      if (gif && !ShouldKeepGifFrame(timestamp, gif_emit_target_hns)) {
        emit_progress(timestamp);
        continue;
      }
      if (!ExtractTopDownBgra(sample.Get(), source_w, source_h, &top_down)) {
        cancel_encoder();
        // No HRESULT in hand — the classification rides on the device probe
        // alone, same as the no-video-frames site.
        return Failure(request.destination_path,
                       "export: failed to read a decoded video frame buffer.",
                       /*disk_full=*/false, device_lost(S_OK));
      }
      if (const HRESULT copy_hr = source_bitmap->CopyFromMemory(
              nullptr, top_down.data(), source_w * 4u);
          FAILED(copy_hr)) {
        cancel_encoder();
        return Failure(request.destination_path,
                       "export: ID2D1Bitmap::CopyFromMemory failed.",
                       /*disk_full=*/false, device_lost(copy_hr));
      }

      // Phase 9.4: advance the camera's held frame BEFORE BeginDraw (the upload
      // is a CopyFromMemory, kept outside the draw like the screen frame above).
      // The camera's video frame tracks SOURCE time (frame_ms) so it stays
      // synced to the screen frame being shown — even under clips, where the
      // forward-only pull absorbs the source skip across a cut (§5.5). Only the
      // intro/outro ANIMATION clock (in Draw, below) moves to edited time.
      if (camera_renderer != nullptr) {
        camera_renderer->Advance(frame_ms);
      }

      // Fresh output texture per frame: the encoder MFT may hold the
      // previous frame's surface asynchronously, so reuse would risk
      // overwriting a frame still in flight.
      D3D11_TEXTURE2D_DESC desc{};
      desc.Width = canvas.width;
      desc.Height = canvas.height;
      desc.MipLevels = 1;
      desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_DEFAULT;
      desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      ComPtr<ID3D11Texture2D> out_texture;
      if (const HRESULT tex_hr = device.device()->CreateTexture2D(
              &desc, nullptr, out_texture.GetAddressOf());
          FAILED(tex_hr)) {
        cancel_encoder();
        return Failure(request.destination_path,
                       HrWithDeviceState(
                           "export: CreateTexture2D failed for an output "
                           "frame",
                           tex_hr, device.device()),
                       /*disk_full=*/false, device_lost(tex_hr));
      }
      ComPtr<IDXGISurface> out_surface;
      if (FAILED(out_texture.As(&out_surface))) {
        cancel_encoder();
        return Failure(request.destination_path,
                       "export: output texture has no IDXGISurface.",
                       /*disk_full=*/false, device_lost(S_OK));
      }
      const D2D1_BITMAP_PROPERTIES1 target_props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_TARGET,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_PREMULTIPLIED));
      ComPtr<ID2D1Bitmap1> target_bitmap;
      if (const HRESULT tgt_hr = d2d_ctx->CreateBitmapFromDxgiSurface(
              out_surface.Get(), &target_props, target_bitmap.GetAddressOf());
          FAILED(tgt_hr)) {
        cancel_encoder();
        return Failure(request.destination_path,
                       "export: CreateBitmapFromDxgiSurface failed.",
                       /*disk_full=*/false, device_lost(tgt_hr));
      }

      // Phase 8.3: advance the smart-zoom transform for this frame. The cursor
      // (8.2) is drawn UNDER the same transform, so the cursor and the magnified
      // video share one coordinate space. `frame_ms` (source time) is computed
      // early, above the clip gate.
      ZoomExportController::Frame zf;
      if (zoom_controller != nullptr) {
        // Editing port (clips, D4): the exponential smoother must ease in
        // EDITED time (viewer time). Under a cut the SOURCE dt spikes across the
        // gap and would snap the zoom, so feed the edited dt; `frame_ms` stays
        // SOURCE for segment lookup (auto-zoom segments are source-click-keyed).
        const double dt_seconds =
            clipping
                ? (prev_edited_ms >= 0
                       ? static_cast<double>(*edited - prev_edited_ms) / 1000.0
                       : 1.0 / static_cast<double>(fps_fallback))
                : (prev_frame_hns >= 0
                       ? static_cast<double>(timestamp - prev_frame_hns) /
                             10'000'000.0
                       : 1.0 / static_cast<double>(fps_fallback));
        zf = zoom_controller->Advance(frame_ms, dt_seconds);
      }
      prev_frame_hns = timestamp;
      if (clipping) {
        prev_edited_ms = *edited;
      }
      const bool zooming = zf.active && zf.zoom > 1.0;

      // The content pass — video + cursor + click ripples under the shared
      // clip/zoom transform. A lambda because the editing port's color grade
      // draws it into the FLOAT16 intermediate (graded before the camera),
      // while the ungraded path draws it straight onto the output target —
      // one body, two destinations, zero drift.
      const auto draw_content = [&]() {
        // Content clip: rounded layer when a corner radius is set, else an
        // axis-aligned clip to the content rect when drawing a cursor or a zoom
        // (so neither bleeds into the padding/background). No clip otherwise —
        // the plain composition path stays byte-identical to before.
        bool pushed_layer = false;
        bool pushed_clip = false;
        if (rounded_clip != nullptr) {
          d2d_ctx->PushLayer(
              D2D1::LayerParameters1(D2D1::InfiniteRect(), rounded_clip.Get(),
                                     D2D1_ANTIALIAS_MODE_PER_PRIMITIVE),
              rounded_layer.Get());
          pushed_layer = true;
        } else if (zooming || cursor_renderer != nullptr) {
          d2d_ctx->PushAxisAlignedClip(dest_rect, D2D1_ANTIALIAS_MODE_ALIASED);
          pushed_clip = true;
        }

        // Apply the zoom transform (identity when not zooming). The clip above
        // was pushed under the identity transform, so it stays in canvas space
        // while the content below is magnified about the (clamped) focus
        // center.
        if (zooming) {
          const double cw = content.width;
          const double ch = content.height;
          const double half = 0.5 / zf.zoom;
          const double window_left = (zf.center_x - half) * cw;
          const double window_top = (zf.center_y - half) * ch;
          const D2D1_MATRIX_3X2_F zoom_m =
              D2D1::Matrix3x2F::Translation(
                  -(static_cast<float>(content.x + window_left)),
                  -(static_cast<float>(content.y + window_top))) *
              D2D1::Matrix3x2F::Scale(static_cast<float>(zf.zoom),
                                      static_cast<float>(zf.zoom)) *
              D2D1::Matrix3x2F::Translation(static_cast<float>(content.x),
                                            static_cast<float>(content.y));
          d2d_ctx->SetTransform(zoom_m);
        }

        d2d_ctx->DrawBitmap(source_bitmap.Get(), dest_rect, 1.0f,
                            D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
        if (cursor_renderer != nullptr) {
          cursor_renderer->Draw(d2d_ctx.Get(), frame_ms, dest_rect,
                                static_cast<double>(source_w),
                                static_cast<double>(source_h),
                                request.cursor_size);
          // Phase 8.4: click ripples, drawn under the same transform so they
          // stay aligned with the cursor + smart zoom.
          cursor_renderer->DrawClicks(d2d_ctx.Get(), frame_ms, dest_rect,
                                      static_cast<double>(source_w),
                                      static_cast<double>(source_h));
        }
        if (zooming) {
          d2d_ctx->SetTransform(D2D1::Matrix3x2F::Identity());
        }
        if (pushed_layer) {
          d2d_ctx->PopLayer();
        } else if (pushed_clip) {
          d2d_ctx->PopAxisAlignedClip();
        }
      };

      // Editing port (color), pass 1 of 2: the graded path renders the
      // content into the transparent-backed FLOAT16 intermediate so the
      // grade hits the screen video + cursor + clicks — and only them —
      // before the background/camera composite (macOS precomposited-canvas
      // order).
      if (grading) {
        d2d_ctx->SetTarget(content_bitmap.Get());
        d2d_ctx->BeginDraw();
        d2d_ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
        draw_content();
        const HRESULT content_hr = d2d_ctx->EndDraw();
        if (FAILED(content_hr)) {
          d2d_ctx->SetTarget(nullptr);
          cancel_encoder();
          return Failure(
              request.destination_path,
              Hr("export: Direct2D EndDraw failed (graded content pass)",
                 content_hr),
              /*disk_full=*/false, device_lost(content_hr));
        }
      }

      d2d_ctx->SetTarget(target_bitmap.Get());
      d2d_ctx->BeginDraw();
      // Background first (fills the whole canvas, including padding margins
      // and letterbox bars), then the video on top — clipped to a rounded
      // rect so the corners reveal the background, matching the macOS
      // bg-fill-then-rounded-video draw order.
      d2d_ctx->Clear(clear_color);
      // Background image over the fill, scaled to COVER — wallpaper behaviour,
      // matching the preview compositor exactly so the two agree.
      if (export_bg_image != nullptr) {
        const D2D1_SIZE_F img = export_bg_image->GetSize();
        const D2D1_SIZE_F surface = d2d_ctx->GetSize();
        const RectF src = background::ComputeCoverSourceRect(
            SizeF{img.width, img.height},
            SizeF{surface.width, surface.height});
        const D2D1_RECT_F src_rect = D2D1::RectF(
            static_cast<float>(src.x), static_cast<float>(src.y),
            static_cast<float>(src.x + src.width),
            static_cast<float>(src.y + src.height));
        d2d_ctx->DrawBitmap(
            export_bg_image,
            D2D1::RectF(0.0f, 0.0f, surface.width, surface.height), 1.0f,
            D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, &src_rect);
      }
      if (grading) {
        // The intermediate is canvas-sized, so the graded output lands at the
        // origin 1:1 — no scaling, no interpolation surprises.
        d2d_ctx->DrawImage(grade_chain.Output());
      } else {
        draw_content();
      }
      // Phase 9.4: the camera bubble draws LAST, in canvas space with an
      // identity transform (the zoom transform was reset above and the content
      // clip/layer popped), so it sits on top of the screen + cursor + clicks
      // and is NOT magnified by smart zoom. Its own mask clips the bubble.
      if (camera_renderer != nullptr) {
        // The animation clock must share the same time base as the clip it
        // animates over. Under clips (D4, §5.5) the intro/outro run in EDITED
        // time (the trimmed length = edited_total_ms) at the frame's edited
        // position — the camera's VIDEO frame was already advanced in SOURCE
        // time above, so the two time bases are deliberately split. Without
        // clips: frame_ms + the rebased source duration (raw MF_PD_DURATION
        // keeps the container's PTS base, so passing it unrebased would put the
        // outro window past the last reachable frame_ms and it would never
        // finish; recorder audio tails are well under one outro).
        const std::int64_t camera_clock_ms = clipping ? *edited : frame_ms;
        const std::int64_t camera_total_ms =
            clipping ? edited_total_ms
                     : (duration_hns > first_video_hns
                            ? (duration_hns - first_video_hns) / 10000
                            : 0);
        // `zf.zoom` is the smoothed screen zoom for THIS frame. It only scales
        // the bubble; the camera is still drawn in canvas space, outside the
        // zoom transform the video and cursor share.
        camera_renderer->Draw(d2d_ctx.Get(), camera_clock_ms, camera_total_ms,
                              zf.zoom);
      }
      const HRESULT end_hr = d2d_ctx->EndDraw();
      d2d_ctx->SetTarget(nullptr);
      if (FAILED(end_hr)) {
        cancel_encoder();
        return Failure(request.destination_path,
                       Hr("export: Direct2D EndDraw failed", end_hr),
                       /*disk_full=*/false, device_lost(end_hr));
      }
      // Flush so the composite completes before the encoder MFT reads the
      // texture on its own thread.
      device.context()->Flush();

      clingfy::capture::CapturedVideoFrame frame;
      frame.texture = out_texture;
      frame.width = canvas.width;
      frame.height = canvas.height;
      // Editing port (clips, 3a): re-stamp onto the compacted edited timeline.
      // The encoder rebases video by this first written frame's PTS, so the
      // whole edited timeline is anchored here; audio is shifted to the same
      // origin below (T2). Without clips: the raw source PTS, unchanged.
      frame.timestamp_hns = clipping ? (*edited * 10000) : timestamp;
      if (clipping && origin_edited_hns < 0) {
        origin_edited_hns = *edited * 10000;
      }
      if (auto err = write_video_frame(frame)) {
        cancel_encoder();
        return Failure(request.destination_path,
                       "export: encoder WriteVideoFrame failed — " +
                           err->message,
                       IsDiskFullHresult(err->hr), device_lost(err->hr));
      }
      ++video_frames;
      // A/V origin alignment (T2): now that the first kept video frame has
      // anchored the timeline, flush any audio buffered before it — subtracting
      // the common origin so it lands on the same zero as the video (the
      // encoder does NOT rebase audio, so we do it here).
      if (clipping && origin_edited_hns >= 0 && !pending_audio.empty()) {
        for (auto& buffered : pending_audio) {
          buffered.timestamp_hns = std::max<std::int64_t>(
              0, buffered.timestamp_hns - origin_edited_hns);
          if (auto err = encoder.WriteAudioPacket(buffered)) {
            cancel_encoder();
            return Failure(request.destination_path,
                           "export: encoder WriteAudioPacket (clip flush) "
                           "failed — " +
                               err->message,
                           IsDiskFullHresult(err->hr), device_lost(err->hr));
          }
          ++audio_packets;
        }
        pending_audio.clear();
      }
      // Editing port (clips, 3b-2b): drain the reorder audio pump up to this
      // frame's edited position, so audio is written just BEHIND the video and
      // never races far ahead of it (the sink writer throttles when the two
      // streams' timestamps diverge). The pump origin-shifts by the same zero
      // the video anchored on, so A/V stays aligned.
      if (reorder_audio_pump != nullptr && origin_edited_hns >= 0) {
        const std::int64_t edited_frame_limit =
            (*edited * kExportAudioSampleRate) / 1000;
        if (auto err = reorder_audio_pump->PumpUpTo(edited_frame_limit,
                                                    origin_edited_hns, encoder,
                                                    &audio_packets)) {
          cancel_encoder();
          return Failure(
              request.destination_path,
              "export: reorder audio pump WriteAudioPacket failed — " +
                  err->message,
              IsDiskFullHresult(err->hr), device_lost(err->hr));
        }
      }
      // Audio separation (D8): drain the per-track pumps to this frame's
      // timeline position — the same just-behind-the-video cadence as the
      // reorder pump. Clipping paces by the edited position once the origin
      // is anchored; a no-clip export paces by the frame's source ms
      // (edited == source) with a zero origin (the recorder writes from
      // PTS 0, matching the embedded no-clip path's verbatim timestamps).
      if (sep_merge.has_value() && (!clipping || origin_edited_hns >= 0)) {
        const std::int64_t pos_ms = clipping ? *edited : frame_ms;
        const std::int64_t sep_origin = clipping ? origin_edited_hns : 0;
        const std::int64_t limit = (pos_ms * kExportAudioSampleRate) / 1000;
        if (auto err = drain_separated(limit, sep_origin)) {
          cancel_encoder();
          return Failure(
              request.destination_path,
              "export: separated audio pump WriteAudioPacket failed — " +
                  err->message,
              IsDiskFullHresult(err->hr), device_lost(err->hr));
        }
      }
      if (gif) {
        gif_emit_target_hns = AdvanceGifEmitTarget(gif_emit_target_hns, timestamp);
      }
      // Progress: the source PTS is non-monotonic under reorder (backward
      // seeks), so drive the bar from the EDITED position instead (D5). The
      // monotonic path keeps the source-PTS fraction.
      if (reorder && edited_total_ms > 0) {
        report_progress_frac(static_cast<double>(*edited) /
                             static_cast<double>(edited_total_ms));
      } else {
        emit_progress(timestamp);
      }
    } else if (has_audio && actual_index == audio_index) {
      ComPtr<IMFMediaBuffer> audio_buffer;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(
              audio_buffer.GetAddressOf())) &&
          audio_buffer != nullptr) {
        BYTE* data = nullptr;
        DWORD max_len = 0;
        DWORD cur_len = 0;
        if (SUCCEEDED(audio_buffer->Lock(&data, &max_len, &cur_len)) &&
            data != nullptr && cur_len > 0) {
          const std::uint32_t int16_count =
              cur_len / static_cast<std::uint32_t>(sizeof(std::int16_t));
          clingfy::audio::MixedPacket packet;
          packet.samples.resize(int16_count);
          std::memcpy(packet.samples.data(), data,
                      static_cast<size_t>(int16_count) * sizeof(std::int16_t));
          packet.frame_count = int16_count / 2u;  // stereo interleaved
          packet.timestamp_hns = timestamp;
          audio_buffer->Unlock();
          // Slice 4: scale the decoded PCM by the resolved gain/volume/
          // normalize stages (a no-op when both are 1.0). Touches sample
          // values only — never frame_count or timestamp, so A/V sync holds.
          ApplyAudioGain(packet.samples.data(), packet.samples.size(),
                         audio_stages);
          if (!clipping) {
            // No clips: carry the packet through at its source PTS (unchanged).
            if (auto err = encoder.WriteAudioPacket(packet)) {
              cancel_encoder();
              return Failure(request.destination_path,
                             "export: encoder WriteAudioPacket failed — " +
                                 err->message,
                             IsDiskFullHresult(err->hr),
                             device_lost(err->hr));
            }
            ++audio_packets;
          } else if (first_video_hns < 0) {
            // Audio ahead of the first decoded video frame: no timeline anchor
            // yet, and under a head-trim it precedes the kept range. Drop it
            // (fixes outside-voice #2 — never key audio off an unset anchor).
          } else {
            // Editing port (clips, 3b-1): sample-accurate keep/trim against the
            // edited timeline. Unlike 3a's packet-granular keep/drop (which
            // leaked up to ~21 ms of cut-adjacent audio at a seam), a packet
            // straddling a cut is trimmed to the exact frame at the boundary,
            // and a packet spanning a cut contributes to BOTH adjacent kept
            // ranges (the leading audio of the post-cut range is no longer
            // dropped). Each kept sub-run re-stamps onto the edited timeline and
            // aligns to the shared origin (T2), buffering until the first kept
            // video frame anchors it. Only MONOTONIC ranges take this in-loop
            // path; reorder audio is stitched by the decoupled ReorderAudioPump
            // (the main reader's audio is deselected under reorder, 3b-2b).
            const std::int64_t packet_src_start_frame =
                ((timestamp - first_video_hns) * kExportAudioSampleRate) /
                10'000'000;
            const auto copies = clip_audio::PlanKeptAudioCopies(
                packet_src_start_frame, packet.frame_count, request.clip_ranges,
                kExportAudioSampleRate);
            for (const auto& span : copies) {
              clingfy::audio::MixedPacket sub;
              sub.frame_count = span.frame_count;
              const std::size_t begin =
                  static_cast<std::size_t>(span.src_offset_frames) *
                  kExportAudioChannels;
              const std::size_t end =
                  begin + static_cast<std::size_t>(span.frame_count) *
                              kExportAudioChannels;
              sub.samples.assign(packet.samples.begin() + begin,
                                 packet.samples.begin() + end);
              const std::int64_t edited_hns =
                  (span.edited_start_frame * 10'000'000) /
                  kExportAudioSampleRate;
              sub.timestamp_hns = edited_hns;  // absolute edited
              if (origin_edited_hns < 0) {
                // Timeline not yet anchored (first kept video not written):
                // buffer; flushed + origin-subtracted on that write.
                pending_audio.push_back(std::move(sub));
              } else {
                sub.timestamp_hns =
                    std::max<std::int64_t>(0, edited_hns - origin_edited_hns);
                if (auto err = encoder.WriteAudioPacket(sub)) {
                  cancel_encoder();
                  return Failure(request.destination_path,
                                 "export: encoder WriteAudioPacket failed — " +
                                     err->message,
                                 IsDiskFullHresult(err->hr),
                                 device_lost(err->hr));
                }
                ++audio_packets;
              }
            }
          }
        } else if (data != nullptr) {
          audio_buffer->Unlock();
        }
      }
    }
  }

  if (video_frames == 0) {
    cancel_encoder();
    // S_OK carries no signal of its own here — the classification rides
    // entirely on the device probe (a lost device can make the reader
    // return EOS-without-frames instead of a failing HRESULT).
    return Failure(request.destination_path,
                   "export: no video frames were decoded from the source.",
                   /*disk_full=*/false, device_lost(S_OK));
  }

  // Editing port (clips, 3b-2b): drain the reorder audio pump's tail — the
  // trailing silence and any audio whose edited position sits past the last
  // written video frame — before finalizing.
  if (reorder_audio_pump != nullptr && origin_edited_hns >= 0) {
    if (auto err = reorder_audio_pump->Flush(origin_edited_hns, encoder,
                                             &audio_packets)) {
      cancel_encoder();
      return Failure(
          request.destination_path,
          "export: reorder audio pump flush failed — " + err->message,
          IsDiskFullHresult(err->hr), device_lost(err->hr));
    }
  }

  // Audio separation (D8): drain both pumps to plan end. Both run the SAME
  // plan, so their totals converge and the merge FIFOs empty here.
  if (sep_merge.has_value() && (!clipping || origin_edited_hns >= 0)) {
    const std::int64_t sep_origin = clipping ? origin_edited_hns : 0;
    if (auto err = drain_separated(std::numeric_limits<std::int64_t>::max(),
                                   sep_origin)) {
      cancel_encoder();
      return Failure(
          request.destination_path,
          "export: separated audio pump flush failed — " + err->message,
          IsDiskFullHresult(err->hr), device_lost(err->hr));
    }
  }

  if (auto err = finalize_encoder()) {
    // Both encoders release their writer/stream even on a failed Finalize,
    // so the partial-output removal inside Failure() is not blocked by a
    // still-open file handle.
    return Failure(request.destination_path,
                   "export: encoder finalize failed — " + err->message,
                   IsDiskFullHresult(err->hr), device_lost(err->hr));
  }

  // Slice 5A: terminal 1.0 so the UI lands exactly at 100% (matches macOS,
  // which emits the upper bound on completion).
  if (request.on_progress) {
    request.on_progress(1.0);
  }

  RenderResult out;
  out.ok = true;
  out.output_width = canvas.width;
  out.output_height = canvas.height;
  out.video_frames_written = video_frames;
  out.audio_packets_written = audio_packets;
  out.had_audio = has_audio || sep_merge.has_value();
  return out;
}

}  // namespace clingfy::capture::export_
