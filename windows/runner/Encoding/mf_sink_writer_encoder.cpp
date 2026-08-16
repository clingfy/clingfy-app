#include "Encoding/mf_sink_writer_encoder.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mmreg.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>

#include "Audio/audio_mixer.h"
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
    clingfy::graphics::D3DDevice& device,
    const std::optional<AudioEncoderConfig>& audio) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (open_) {
    return ToError("MfSinkWriterEncoder::Open called on an open encoder.",
                   E_NOT_VALID_STATE);
  }
  if (auto invalid = config.Validate()) {
    return EncoderError{*invalid, E_INVALIDARG};
  }
  if (audio.has_value()) {
    if (auto invalid_audio = audio->Validate()) {
      return EncoderError{*invalid_audio, E_INVALIDARG};
    }
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
  audio_config_ = audio;
  sample_duration_hns_ =
      static_cast<std::int64_t>(10'000'000) / static_cast<std::int64_t>(config.fps);
  origin_timestamp_hns_ = -1;
  last_sample_time_hns_ = -1;
  last_audio_sample_time_hns_ = -1;
  samples_written_ = 0;
  audio_samples_written_ = 0;
  has_audio_stream_ = false;

  if (auto err = ConfigureVideoMediaTypes()) {
    Cancel();
    return err;
  }
  if (audio_config_.has_value()) {
    if (auto err = ConfigureAudioMediaTypes()) {
      Cancel();
      return err;
    }
  }

  hr = sink_writer_->BeginWriting();
  if (FAILED(hr)) {
    Cancel();
    return ToError("IMFSinkWriter::BeginWriting failed.", hr);
  }

  open_ = true;
  return std::nullopt;
}

std::optional<EncoderError> MfSinkWriterEncoder::ConfigureVideoMediaTypes() {
  // Output: H.264 in MP4. Picked the Main profile so the result plays in
  // QuickTime / VLC / browsers without re-muxing.
  Microsoft::WRL::ComPtr<IMFMediaType> output_type;
  HRESULT hr = ::MFCreateMediaType(output_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for output H.264 type.", hr);
  }
  output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  const bool hevc = config_.codec == VideoCodec::kHevc;
  output_type->SetGUID(MF_MT_SUBTYPE,
                       hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264);
  output_type->SetUINT32(MF_MT_AVG_BITRATE, config_.avg_bitrate_bps);
  output_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  // The profile attribute is NOT a drop-in swap. Both codecs report through
  // MF_MT_MPEG2_PROFILE, but the value spaces are different enums:
  // eAVEncH264VProfile_Main for H.264 vs eAVEncH265VProfile_Main_420_8 for
  // HEVC. Main/4:2:0/8-bit is the profile every HEVC decoder handles, which is
  // what a user exporting a screen recording needs — not a 10-bit or 4:4:4
  // variant that half their playback targets would refuse.
  output_type->SetUINT32(MF_MT_MPEG2_PROFILE,
                         hevc ? static_cast<UINT32>(
                                    eAVEncH265VProfile_Main_420_8)
                              : static_cast<UINT32>(eAVEncH264VProfile_Main));
  // Issue #294: bound the GOP so a seek's keyframe lead-in has a known worst
  // case. Set on the OUTPUT type before AddStream, which is the only point
  // the sink writer reads it. Best-effort by design — the return is ignored
  // because an MFT that rejects or ignores the hint must still record, it
  // just keeps the encoder's own spacing (see the field's comment).
  //
  // Applies to HEVC too: the attribute is codec-agnostic, and an HEVC export
  // is seeked by exactly the same consumers.
  if (config_.keyframe_interval_frames > 0) {
    output_type->SetUINT32(MF_MT_MAX_KEYFRAME_SPACING,
                           config_.keyframe_interval_frames);
  }
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

std::optional<EncoderError> MfSinkWriterEncoder::ConfigureAudioMediaTypes() {
  if (!audio_config_.has_value()) {
    return std::nullopt;
  }
  const AudioEncoderConfig& cfg = *audio_config_;

  // Output: AAC LC. The Sink Writer's AAC encoder MFT accepts a small
  // matrix of (sample rate, channels, bitrate) tuples; the pinned
  // 48 kHz / 2-channel / 128 kbps combination is universally
  // supported and matches the WASAPI mixer's output.
  Microsoft::WRL::ComPtr<IMFMediaType> output_type;
  HRESULT hr = ::MFCreateMediaType(output_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for AAC output type.", hr);
  }
  output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  output_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  output_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, cfg.bits_per_sample);
  output_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, cfg.sample_rate_hz);
  output_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, cfg.channel_count);
  output_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          cfg.avg_bitrate_bps / 8);
  // AAC Profile Level Indication 0x29 = AAC-LC, 2 channels, 48 kHz —
  // the exact value here is what the SinkWriter inspects to pick the
  // matching encoder MFT.
  output_type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);

  hr = sink_writer_->AddStream(output_type.Get(), &audio_stream_index_);
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::AddStream failed for AAC output.", hr);
  }

  // Input: PCM int16, same rate / channels as the output. The mixer
  // produces samples in exactly this layout so no resampling is needed.
  Microsoft::WRL::ComPtr<IMFMediaType> input_type;
  hr = ::MFCreateMediaType(input_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for PCM input type.", hr);
  }
  input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  input_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  input_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, cfg.bits_per_sample);
  input_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, cfg.sample_rate_hz);
  input_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, cfg.channel_count);
  const UINT32 block_align = cfg.channel_count * (cfg.bits_per_sample / 8u);
  input_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, block_align);
  input_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          cfg.sample_rate_hz * block_align);
  input_type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);

  hr = sink_writer_->SetInputMediaType(audio_stream_index_, input_type.Get(),
                                        nullptr);
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::SetInputMediaType failed for PCM input.",
                   hr);
  }

  has_audio_stream_ = true;
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

std::optional<EncoderError> MfSinkWriterEncoder::WriteAudioPacket(
    const clingfy::audio::MixedPacket& packet) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return ToError("Encoder is not open; call Open() first.",
                   E_NOT_VALID_STATE);
  }
  if (!has_audio_stream_) {
    // Video-only recording — silently accept and drop.
    return std::nullopt;
  }
  if (packet.frame_count == 0 || packet.samples.empty()) {
    return std::nullopt;
  }

  const std::uint32_t bytes_per_sample =
      audio_config_->bits_per_sample / 8u;
  const std::uint32_t channels = audio_config_->channel_count;
  const std::uint32_t byte_length = packet.frame_count * channels *
                                     bytes_per_sample;
  if (byte_length == 0) {
    return std::nullopt;
  }

  Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = ::MFCreateMemoryBuffer(byte_length, buffer.GetAddressOf());
  if (FAILED(hr) || buffer == nullptr) {
    return ToError("MFCreateMemoryBuffer failed for AAC input sample.", hr);
  }
  BYTE* mapped = nullptr;
  hr = buffer->Lock(&mapped, nullptr, nullptr);
  if (FAILED(hr) || mapped == nullptr) {
    return ToError("IMFMediaBuffer::Lock failed for AAC input sample.", hr);
  }
  std::memcpy(mapped, packet.samples.data(), byte_length);
  buffer->Unlock();
  buffer->SetCurrentLength(byte_length);

  Microsoft::WRL::ComPtr<IMFSample> sample;
  hr = ::MFCreateSample(sample.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateSample failed for AAC input sample.", hr);
  }
  sample->AddBuffer(buffer.Get());

  std::int64_t sample_time = packet.timestamp_hns;
  if (sample_time < 0) {
    sample_time = 0;
  }
  // AAC stream's own monotonic-time guarantee — mirrors the video path
  // for the same MF_E_INVALIDREQUEST reason on some encoder MFTs.
  if (sample_time <= last_audio_sample_time_hns_) {
    sample_time = last_audio_sample_time_hns_ + 1;
  }
  const std::int64_t duration_hns =
      (static_cast<std::int64_t>(packet.frame_count) * 10'000'000) /
      static_cast<std::int64_t>(audio_config_->sample_rate_hz);
  sample->SetSampleTime(sample_time);
  sample->SetSampleDuration(duration_hns);
  // Every AAC sample is a clean point (no inter-sample dependencies in
  // the bitstream), so flag it accordingly — without this, MP4 readers
  // may complain about missing sync samples.
  sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);

  hr = sink_writer_->WriteSample(audio_stream_index_, sample.Get());
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::WriteSample failed for AAC input.", hr);
  }
  last_audio_sample_time_hns_ = sample_time;
  ++audio_samples_written_;
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
  has_audio_stream_ = false;
  samples_written_ = 0;
  audio_samples_written_ = 0;
  origin_timestamp_hns_ = -1;
  last_sample_time_hns_ = -1;
  last_audio_sample_time_hns_ = -1;
}

bool MfSinkWriterEncoder::open() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return open_;
}

std::uint64_t MfSinkWriterEncoder::samples_written() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return samples_written_;
}

std::uint64_t MfSinkWriterEncoder::audio_samples_written_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return audio_samples_written_;
}

}  // namespace clingfy::encoding
