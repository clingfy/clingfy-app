#include "Encoding/audio_sidecar_writer.h"

#include <mfapi.h>
#include <mferror.h>

#include <atomic>
#include <cstring>

namespace clingfy::encoding {

namespace {

// Idempotent MF startup — same pattern as MfSinkWriterEncoder (startup is
// paired with MFShutdown only at process exit).
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

AudioSidecarWriter::AudioSidecarWriter() = default;

AudioSidecarWriter::~AudioSidecarWriter() {
  Cancel();
}

std::optional<EncoderError> AudioSidecarWriter::Open(
    const std::string& output_path) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (open_) {
    return ToError("AudioSidecarWriter::Open called on an open writer.",
                   E_NOT_VALID_STATE);
  }
  if (output_path.empty()) {
    return ToError("AudioSidecarWriter::Open requires an output path.",
                   E_INVALIDARG);
  }
  EnsureMediaFoundationStarted();

  // No writer attributes: an audio-only file needs neither the D3D manager
  // nor hardware transforms — the AAC encoder MFT is software either way.
  const std::wstring path = Utf8ToWide(output_path);
  HRESULT hr = ::MFCreateSinkWriterFromURL(path.c_str(), nullptr, nullptr,
                                            sink_writer_.GetAddressOf());
  if (FAILED(hr) || sink_writer_ == nullptr) {
    sink_writer_.Reset();
    return ToError(
        "MFCreateSinkWriterFromURL failed for the audio sidecar — the "
        "output path may be unwritable.",
        hr);
  }

  last_sample_time_hns_ = -1;
  samples_written_ = 0;

  if (auto err = ConfigureMediaTypes()) {
    sink_writer_.Reset();
    return err;
  }

  hr = sink_writer_->BeginWriting();
  if (FAILED(hr)) {
    sink_writer_.Reset();
    return ToError("IMFSinkWriter::BeginWriting failed for the audio sidecar.",
                   hr);
  }

  open_ = true;
  return std::nullopt;
}

std::optional<EncoderError> AudioSidecarWriter::ConfigureMediaTypes() {
  const AudioEncoderConfig& cfg = config_;

  // Output: AAC-LC — byte-for-byte the tuple MfSinkWriterEncoder pins for
  // the premixed track (48 kHz / stereo / 128 kbps, profile level 0x29).
  Microsoft::WRL::ComPtr<IMFMediaType> output_type;
  HRESULT hr = ::MFCreateMediaType(output_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for the sidecar AAC output.", hr);
  }
  output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  output_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  output_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, cfg.bits_per_sample);
  output_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, cfg.sample_rate_hz);
  output_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, cfg.channel_count);
  output_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          cfg.avg_bitrate_bps / 8);
  output_type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);

  hr = sink_writer_->AddStream(output_type.Get(), &stream_index_);
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::AddStream failed for the sidecar AAC.", hr);
  }

  // Input: PCM int16, same rate / channels — the mixer-thread tee renders
  // each source into exactly this layout.
  Microsoft::WRL::ComPtr<IMFMediaType> input_type;
  hr = ::MFCreateMediaType(input_type.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateMediaType failed for the sidecar PCM input.", hr);
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

  hr = sink_writer_->SetInputMediaType(stream_index_, input_type.Get(),
                                        nullptr);
  if (FAILED(hr)) {
    return ToError(
        "IMFSinkWriter::SetInputMediaType failed for the sidecar PCM input.",
        hr);
  }
  return std::nullopt;
}

std::optional<EncoderError> AudioSidecarWriter::WriteSamples(
    const std::int16_t* interleaved_samples,
    std::uint32_t frame_count,
    std::int64_t timestamp_hns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return ToError("AudioSidecarWriter is not open.", E_NOT_VALID_STATE);
  }
  if (interleaved_samples == nullptr || frame_count == 0) {
    return std::nullopt;
  }

  const std::uint32_t bytes_per_sample = config_.bits_per_sample / 8u;
  const std::uint32_t byte_length =
      frame_count * config_.channel_count * bytes_per_sample;

  Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = ::MFCreateMemoryBuffer(byte_length, buffer.GetAddressOf());
  if (FAILED(hr) || buffer == nullptr) {
    return ToError("MFCreateMemoryBuffer failed for a sidecar sample.", hr);
  }
  BYTE* mapped = nullptr;
  hr = buffer->Lock(&mapped, nullptr, nullptr);
  if (FAILED(hr) || mapped == nullptr) {
    return ToError("IMFMediaBuffer::Lock failed for a sidecar sample.", hr);
  }
  std::memcpy(mapped, interleaved_samples, byte_length);
  buffer->Unlock();
  buffer->SetCurrentLength(byte_length);

  Microsoft::WRL::ComPtr<IMFSample> sample;
  hr = ::MFCreateSample(sample.GetAddressOf());
  if (FAILED(hr)) {
    return ToError("MFCreateSample failed for a sidecar sample.", hr);
  }
  sample->AddBuffer(buffer.Get());

  std::int64_t sample_time = timestamp_hns;
  if (sample_time < 0) {
    sample_time = 0;
  }
  // Monotonic-time guarantee for the AAC MFT — mirrors the premix path.
  if (sample_time <= last_sample_time_hns_) {
    sample_time = last_sample_time_hns_ + 1;
  }
  const std::int64_t duration_hns =
      (static_cast<std::int64_t>(frame_count) * 10'000'000) /
      static_cast<std::int64_t>(config_.sample_rate_hz);
  sample->SetSampleTime(sample_time);
  sample->SetSampleDuration(duration_hns);
  sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);

  hr = sink_writer_->WriteSample(stream_index_, sample.Get());
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::WriteSample failed for the sidecar.", hr);
  }
  last_sample_time_hns_ = sample_time;
  samples_written_ += frame_count;
  return std::nullopt;
}

std::optional<EncoderError> AudioSidecarWriter::Finalize() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_ || sink_writer_ == nullptr) {
    open_ = false;
    sink_writer_.Reset();
    return std::nullopt;
  }
  const HRESULT hr = sink_writer_->Finalize();
  sink_writer_.Reset();
  open_ = false;
  if (FAILED(hr)) {
    return ToError("IMFSinkWriter::Finalize failed for the audio sidecar.",
                   hr);
  }
  return std::nullopt;
}

void AudioSidecarWriter::Cancel() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_writer_.Reset();
  open_ = false;
}

std::uint64_t AudioSidecarWriter::samples_written() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return samples_written_;
}

}  // namespace clingfy::encoding
