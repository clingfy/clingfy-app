#include "Capture/Export/reorder_audio_pump.h"

#include <mfapi.h>
#include <mferror.h>
#include <propidl.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

#include "Audio/audio_mixer.h"
#include "Encoding/mf_sink_writer_encoder.h"

namespace clingfy::capture::export_ {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kNoStream = 0xFFFFFFFFu;

// Silence is emitted in modest chunks (~20 ms) rather than one giant packet, so
// a long fully-silent slot stays interleaved with the video (no timestamp race
// against the throttling sink writer) and no single allocation is huge.
constexpr std::int64_t kSilenceChunkMs = 20;

std::int64_t FrameToHns(std::int64_t frame, std::int64_t sample_rate_hz) {
  return (frame * 10'000'000) / sample_rate_hz;
}

// A decoded packet's timestamp (hns, source-relative) → its first per-channel
// frame index on the SOURCE audio timeline. Truncating, matching the ms→frame
// conversions the plan uses.
std::int64_t HnsToFrame(std::int64_t ts_hns, std::int64_t sample_rate_hz) {
  return (ts_hns * sample_rate_hz) / 10'000'000;
}

}  // namespace

std::unique_ptr<ReorderAudioPump> ReorderAudioPump::Create(
    const std::wstring& source_path,
    const std::vector<clip_planner::AudioSlot>& slots,
    std::int64_t sample_rate_hz, std::uint32_t channels,
    const AudioGainStages& gain) {
  if (source_path.empty() || sample_rate_hz <= 0 || channels == 0 ||
      slots.empty()) {
    return nullptr;
  }

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(source_path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return nullptr;
  }

  // Find the first audio stream; select only it and force 48 kHz stereo int16
  // PCM (mirrors MeasureSourceAudioPeak / the main reader's audio setup).
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  DWORD audio_index = kNoStream;
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
    if (SUCCEEDED(native->GetGUID(MF_MT_MAJOR_TYPE, &major)) &&
        major == MFMediaType_Audio) {
      audio_index = i;
      break;
    }
  }
  if (audio_index == kNoStream) {
    return nullptr;
  }
  reader->SetStreamSelection(audio_index, TRUE);

  ComPtr<IMFMediaType> pcm_type;
  if (FAILED(::MFCreateMediaType(pcm_type.GetAddressOf()))) {
    return nullptr;
  }
  pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                      static_cast<UINT32>(sample_rate_hz));
  pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  if (FAILED(
          reader->SetCurrentMediaType(audio_index, nullptr, pcm_type.Get()))) {
    return nullptr;
  }

  auto pump = std::unique_ptr<ReorderAudioPump>(new ReorderAudioPump());
  pump->reader_ = std::move(reader);
  pump->audio_index_ = audio_index;
  pump->sample_rate_ = sample_rate_hz;
  pump->channels_ = channels;
  pump->gain_ = gain;
  pump->plan_ = clip_audio::PlanReorderAudioSlots(slots, sample_rate_hz);
  return pump;
}

void ReorderAudioPump::SeekToFrame(std::int64_t source_frame) {
  PROPVARIANT pos;
  PropVariantInit(&pos);
  pos.vt = VT_I8;
  pos.hVal.QuadPart =
      std::max<std::int64_t>(0, FrameToHns(source_frame, sample_rate_));
  reader_->SetCurrentPosition(GUID_NULL, pos);
  PropVariantClear(&pos);
}

bool ReorderAudioPump::done() const { return slot_i_ >= plan_.size(); }

void ReorderAudioPump::PrimeAtEditedFrame(std::int64_t edited_frame) {
  const clip_audio::PumpCursor cursor =
      clip_audio::PrimeReorderCursor(plan_, edited_frame);
  slot_i_ = cursor.slot_index;
  emitted_ = cursor.emitted_frames;
  // A cursor landing in the slot's silence region skips the copy phase
  // entirely (matches the natural emitted_ >= copy_frame_count transition).
  copy_done_ = slot_i_ < plan_.size() &&
               emitted_ >= plan_[slot_i_].copy_frame_count;
  seeked_ = false;
}

std::optional<clingfy::encoding::EncoderError> ReorderAudioPump::Flush(
    std::int64_t origin_hns, clingfy::encoding::MfSinkWriterEncoder& encoder,
    std::uint64_t* audio_packets) {
  return PumpUpTo(std::numeric_limits<std::int64_t>::max(), origin_hns, encoder,
                  audio_packets);
}

std::optional<clingfy::encoding::EncoderError> ReorderAudioPump::PumpUpTo(
    std::int64_t edited_frame_limit, std::int64_t origin_hns,
    clingfy::encoding::MfSinkWriterEncoder& encoder,
    std::uint64_t* audio_packets) {
  // The export sink: absolute edited frame → hns, shifted onto the video's
  // zero (the encoder rebases video by its first written PTS but writes audio
  // verbatim), then written to the sink writer.
  return PumpUpTo(
      edited_frame_limit,
      [&](clingfy::audio::MixedPacket&& packet, std::int64_t edited_frame)
          -> std::optional<clingfy::encoding::EncoderError> {
        packet.timestamp_hns = std::max<std::int64_t>(
            0, FrameToHns(edited_frame, sample_rate_) - origin_hns);
        if (auto err = encoder.WriteAudioPacket(packet)) {
          return err;
        }
        if (audio_packets != nullptr) {
          ++*audio_packets;
        }
        return std::nullopt;
      });
}

std::optional<clingfy::encoding::EncoderError> ReorderAudioPump::PumpUpTo(
    std::int64_t edited_frame_limit, const AudioPacketSink& write) {
  const std::int64_t silence_chunk_frames =
      std::max<std::int64_t>(1, (kSilenceChunkMs * sample_rate_) / 1000);

  while (slot_i_ < plan_.size()) {
    const clip_audio::ReorderAudioSlot& p = plan_[slot_i_];
    const std::int64_t slot_frames = p.copy_frame_count + p.silence_frame_count;

    if (emitted_ >= slot_frames) {
      // Slot fully emitted — advance to the next timeline slot.
      ++slot_i_;
      emitted_ = 0;
      copy_done_ = false;
      seeked_ = false;
      continue;
    }

    // The edited frame the next emit would land on. Stop once it passes the
    // video's current position so audio stays just behind the video.
    const std::int64_t next_edited_frame = p.edited_start_frame + emitted_;
    if (next_edited_frame > edited_frame_limit) {
      return std::nullopt;
    }

    if (!copy_done_ && emitted_ < p.copy_frame_count) {
      // --- Copy phase: pull real PCM from the source window. ---
      if (!seeked_) {
        // Seek to the still-needed position, not the slot start: identical
        // when the slot starts fresh (emitted_ == 0 — the only export case),
        // and skips the already-emitted head after a PrimeAtEditedFrame
        // landed mid-slot. MF undershoots the target; the intersection below
        // trims the lead-in either way.
        SeekToFrame(p.source_in_frame + emitted_);
        seeked_ = true;
      }
      DWORD flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      const HRESULT hr = reader_->ReadSample(audio_index_, 0, nullptr, &flags,
                                             &ts, sample.GetAddressOf());
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
        // The captured audio ended before the slot's copy window was filled;
        // the shortfall becomes silence (handled by the silence phase below).
        copy_done_ = true;
        continue;
      }
      if (sample == nullptr) {
        continue;  // stream tick (gap / format change)
      }
      ComPtr<IMFMediaBuffer> buffer;
      if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) ||
          buffer == nullptr) {
        continue;
      }
      BYTE* data = nullptr;
      DWORD max_len = 0;
      DWORD cur_len = 0;
      if (FAILED(buffer->Lock(&data, &max_len, &cur_len)) || data == nullptr ||
          cur_len == 0) {
        if (data != nullptr) {
          buffer->Unlock();
        }
        continue;
      }
      const std::int64_t packet_frames =
          static_cast<std::int64_t>(cur_len) /
          (static_cast<std::int64_t>(sizeof(std::int16_t)) * channels_);
      const std::int64_t src_start = HnsToFrame(ts, sample_rate_);
      // Intersect the decoded packet with the still-needed copy window. The
      // seek undershoots (MF lands at/before the target), so the first packet
      // can start before the window — trim its head; contiguous packets then
      // tile the window with no gaps.
      const std::int64_t want_start = p.source_in_frame + emitted_;
      const std::int64_t want_end = p.source_in_frame + p.copy_frame_count;
      const std::int64_t i0 = std::max(src_start, want_start);
      const std::int64_t i1 = std::min(src_start + packet_frames, want_end);
      if (i1 <= i0) {
        // Packet entirely before the window (pre-roll after the seek) or
        // entirely past it. Past → the copy is done; before → read the next.
        if (src_start >= want_end) {
          copy_done_ = true;
        }
        buffer->Unlock();
        continue;
      }
      clingfy::audio::MixedPacket sub;
      sub.frame_count = static_cast<std::uint32_t>(i1 - i0);
      const std::size_t begin = static_cast<std::size_t>(i0 - src_start) *
                                channels_;
      const std::size_t count =
          static_cast<std::size_t>(i1 - i0) * channels_;
      const auto* s16 = reinterpret_cast<const std::int16_t*>(data);
      sub.samples.assign(s16 + begin, s16 + begin + count);
      buffer->Unlock();
      ApplyAudioGain(sub.samples.data(), sub.samples.size(), gain_);
      // Defensive: MF audio seeks undershoot (land at/before the target), so
      // the window is normally contiguous. If a seek overshot — or truncation
      // left a 1-frame notch — silence-fill the gap first so audio stays
      // time-aligned (a source gap reads as silence, like macOS insertTimeRange)
      // rather than packing the copy earlier and desyncing the slot.
      if (i0 > want_start) {
        clingfy::audio::MixedPacket gap;
        gap.frame_count = static_cast<std::uint32_t>(i0 - want_start);
        gap.samples.assign(static_cast<std::size_t>(i0 - want_start) * channels_,
                           0);
        const std::int64_t gap_edited = p.edited_start_frame + emitted_;
        if (auto err = write(std::move(gap), gap_edited)) {
          return err;
        }
      }
      const std::int64_t edited_frame =
          p.edited_start_frame + (i0 - p.source_in_frame);
      if (auto err = write(std::move(sub), edited_frame)) {
        return err;
      }
      emitted_ = i1 - p.source_in_frame;
      if (i1 >= want_end) {
        copy_done_ = true;
      }
      continue;
    }

    // --- Silence phase: zero-fill the slot's shortfall to its full duration
    // (§5.2), including any copy the reader couldn't supply (early EOS). ---
    const std::int64_t remaining = slot_frames - emitted_;
    const std::int64_t chunk = std::min(remaining, silence_chunk_frames);
    clingfy::audio::MixedPacket sub;
    sub.frame_count = static_cast<std::uint32_t>(chunk);
    sub.samples.assign(static_cast<std::size_t>(chunk) * channels_, 0);
    const std::int64_t edited_frame = p.edited_start_frame + emitted_;
    if (auto err = write(std::move(sub), edited_frame)) {
      return err;
    }
    emitted_ += chunk;
  }
  return std::nullopt;
}

}  // namespace clingfy::capture::export_
