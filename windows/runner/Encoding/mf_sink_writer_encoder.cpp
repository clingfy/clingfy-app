#include "Encoding/mf_sink_writer_encoder.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>

#include <atomic>
#include <mutex>
#include <string>

#include "Capture/captured_video_frame.h"
#include "Graphics/d3d_device.h"

namespace clingfy::encoding {

namespace {

// Idempotent MF startup. `MFStartup` is paired with `MFShutdown` only at
// process exit — the video source enumerator already follows this
// pattern, and balancing startup/shutdown around every recording would
// churn MF state every time the user presses Record.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  static std::atomic<HRESULT> result{S_OK};
  std::call_once(flag, [] {
    const HRESULT hr = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
    result.store(hr);
  });
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int needed = ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                            static_cast<int>(value.size()),
                                            nullptr, 0);
  if (needed <= 0) {
    return {};
  }
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), out.data(), needed);
  return out;
}

EncoderError ToError(const char* message, HRESULT hr) {
  return EncoderError{std::string(message), hr};
}

}  // namespace

MfSinkWriterEncoder::MfSinkWriterEncoder() = default;
MfSinkWriterEncoder::~MfSinkWriterEncoder() {
  // If the consumer forgot to Finalize, treat it as a Cancel — better to
  // leave a corrupted file than to block in the destructor calling out
  // to MF.
  Cancel();
}

std::optional<EncoderError> MfSinkWriterEncoder::Open(
    const EncoderConfig& config,
    clingfy::graphics::D3DDevice& device) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (open_) {
    return ToError("MfSinkWriterEncoder::Open called on an open encoder.",
                   E_NOT_VALID_STATE);
  }
  if (auto invalid = config.Validate()) {
    return EncoderError{*invalid, E_INVALIDARG};
  }
  EnsureMediaFoundationStarted();

  if (auto dxgi_err = dxgi_manager_.Open(device)) {
    return EncoderError{dxgi_err->message, dxgi_err->hr};
  }

  // Sink-writer attributes: hand the encoder our D3D device manager so
  // the MF pipeline can engage the hardware H.264 MFT, and explicitly
  // enable hardware transforms so MF will pick the GPU-backed encoder
  // over the software one when both are present.
  Microsoft::WRL::ComPtr<IMFAttributes> writer_attrs;
  HRESULT hr = ::MFCreateAttributes(writer_attrs.GetAddressOf(), 4);
  if (FAILED(hr) || writer_attrs == nullptr) {
    Cancel();
    return ToError("MFCreateAttributes failed for SinkWriter config.", hr);
  }
  writer_attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  writer_attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
  writer_attrs->SetUnknown(MF_SINK_WRITER_D3D_MANAGER, dxgi_manager_.Get());

  const std::wstring path = Utf8ToWide(config.output_path);
  hr = ::MFCreateSinkWriterFromURL(path.c_str(), nullptr, writer_attrs.Get(),
                                    sink_writer_.GetAddressOf());
  if (FAILED(hr) || sink_writer_ == nullptr) {
    Cancel();
    return ToError(
        "MFCreateSinkWriterFromURL failed — output path may be unwritable "
        "or the container is not recognized.",
        hr);
  }

  config_ = config;
  sample_duration_hns_ =
      static_cast<std::int64_t>(10'000'000) / static_cast<std::int64_t>(config.fps);
  origin_timestamp_hns_ = -1;
  last_sample_time_hns_ = -1;
  samples_written_ = 0;

  if (auto err = ConfigureMediaTypes()) {
    Cancel();
    return err;
  }

  hr = sink_writer_->BeginWriting();
  if (FAILED(hr)) {
    Cancel();
    return ToError("IMFSinkWriter::BeginWriting failed.", hr);
  }

  open_ = true;
  return std::nullopt;
}

std::optional<EncoderError> MfSinkWriterEncoder::ConfigureMediaTypes() {
  // Output: H.264 in MP4. Picked the Main profile so the result plays in
  // QuickTime / VLC / browsers without re-muxing.
  Microsoft::WRL::ComPtr<IMFMediaType> output_type;
  HRESULT hr = ::MFCreateMediaType(output_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for output H.264 type.", hr);
  }
  output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  output_type->SetUINT32(MF_MT_AVG_BITRATE, config_.avg_bitrate_bps);
  output_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  output_type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
  hr = ::MFSetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE,
                             config_.width, config_.height);
  if (FAILED(hr)) {
    return ToError("MFSetAttributeSize failed for output frame size.", hr);
  }
  hr = ::MFSetAttributeRatio(output_type.Get(), MF_MT_FRAME_RATE,
                              config_.fps, 1);
  if (FAILED(hr)) {
    return ToError("MFSetAttributeRatio failed for output frame rate.", hr);
  }
  ::MFSetAttributeRatio(output_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

  hr = sink_writer_->AddStream(output_type.Get(), &video_stream_index_);
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::AddStream failed for H.264 output.", hr);
  }

  // Input: ARGB32. In Media Foundation's terminology this is the same
  // memory layout WGC produces (B, G, R, A in little-endian); the encoder
  // performs the colorspace conversion as part of the GPU-backed
  // pipeline when MF_SINK_WRITER_D3D_MANAGER is set.
  Microsoft::WRL::ComPtr<IMFMediaType> input_type;
  hr = ::MFCreateMediaType(input_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for input ARGB32 type.", hr);
  }
  input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32);
  input_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  ::MFSetAttributeSize(input_type.Get(), MF_MT_FRAME_SIZE, config_.width,
                       config_.height);
  ::MFSetAttributeRatio(input_type.Get(), MF_MT_FRAME_RATE, config_.fps, 1);
  ::MFSetAttributeRatio(input_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  input_type->SetUINT32(MF_MT_DEFAULT_STRIDE, config_.width * 4);

  hr = sink_writer_->SetInputMediaType(video_stream_index_,
                                        input_type.Get(), nullptr);
  if (FAILED(hr)) {
    return ToError(
        "IMFSinkWriter::SetInputMediaType failed for ARGB32 input — the "
        "selected hardware encoder may not accept BGRA directly.",
        hr);
  }
  return std::nullopt;
}

std::optional<EncoderError> MfSinkWriterEncoder::WriteVideoFrame(
    const clingfy::capture::CapturedVideoFrame& frame) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return ToError("Encoder is not open; call Open() first.",
                   E_NOT_VALID_STATE);
  }
  if (frame.texture == nullptr) {
    // Phase 3B's WGC handler pushed metadata-only frames; we just drop
    // them silently. Phase 3C onwards must populate the texture.
    return std::nullopt;
  }

  // Re-base the timestamp so the MP4 starts at t=0. WGC's
  // SystemRelativeTime begins at an arbitrary boot-relative origin which
  // would otherwise produce a multi-day initial gap in the file.
  if (origin_timestamp_hns_ < 0) {
    origin_timestamp_hns_ = frame.timestamp_hns;
  }
  std::int64_t sample_time = frame.timestamp_hns - origin_timestamp_hns_;
  if (sample_time < 0) {
    sample_time = 0;
  }
  // Some H.264 MFTs reject samples with non-monotonic timestamps with
  // MF_E_INVALIDREQUEST; nudge tied samples forward by one frame
  // duration so the encoder always sees strictly-increasing timestamps.
  if (sample_time <= last_sample_time_hns_) {
    sample_time = last_sample_time_hns_ + 1;
  }

  Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = ::MFCreateDXGISurfaceBuffer(
      __uuidof(ID3D11Texture2D), frame.texture.Get(),
      /*uSubresourceIndex=*/0, /*fBottomUpWhenLinear=*/FALSE,
      buffer.GetAddressOf());
  if (FAILED(hr) || buffer == nullptr) {
    return ToError(
        "MFCreateDXGISurfaceBuffer failed — the captured texture is not "
        "compatible with the encoder.",
        hr);
  }
  // DXGI buffers default to a zero current length; the H.264 MFT uses
  // this to compute its per-sample allocation so we must set it.
  buffer->SetCurrentLength(frame.width * frame.height * 4);

  Microsoft::WRL::ComPtr<IMFSample> sample;
  hr = ::MFCreateSample(sample.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateSample failed.", hr);
  }
  sample->AddBuffer(buffer.Get());
  sample->SetSampleTime(sample_time);
  sample->SetSampleDuration(sample_duration_hns_);

  hr = sink_writer_->WriteSample(video_stream_index_, sample.Get());
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::WriteSample failed.", hr);
  }

  last_sample_time_hns_ = sample_time;
  ++samples_written_;
  return std::nullopt;
}

std::optional<EncoderError> MfSinkWriterEncoder::Finalize() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return std::nullopt;
  }
  if (sink_writer_ == nullptr) {
    open_ = false;
    return std::nullopt;
  }
  HRESULT hr = sink_writer_->Finalize();
  sink_writer_.Reset();
  dxgi_manager_.Reset();
  open_ = false;
  if (FAILED(hr)) {
    return ToError(
        "IMFSinkWriter::Finalize failed — the MP4 may be missing its "
        "MOOV atom and unplayable.",
        hr);
  }
  return std::nullopt;
}

void MfSinkWriterEncoder::Cancel() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_writer_.Reset();
  dxgi_manager_.Reset();
  open_ = false;
  samples_written_ = 0;
  origin_timestamp_hns_ = -1;
  last_sample_time_hns_ = -1;
}

bool MfSinkWriterEncoder::open() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return open_;
}

std::uint64_t MfSinkWriterEncoder::samples_written() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return samples_written_;
}

}  // namespace clingfy::encoding
