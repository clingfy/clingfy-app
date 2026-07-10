#ifndef RUNNER_CAPTURE_EXPORT_REORDER_AUDIO_PUMP_H_
#define RUNNER_CAPTURE_EXPORT_REORDER_AUDIO_PUMP_H_

// mfidl.h (IMFSourceReader / IMFSample) MUST precede mfreadwrite.h, which
// references those types unqualified.
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "Capture/Export/clip_audio_stitch.h"
#include "Capture/Export/clip_playback_planner.h"
#include "Capture/Export/export_audio.h"
#include "Encoding/encoder_error.h"

namespace clingfy::encoding {
class MfSinkWriterEncoder;
}  // namespace clingfy::encoding

// Editing port (clips, Step 3b-2b): the decoupled audio pass for a REORDER
// export.
//
// The reorder video path (3b-2a) reads each kept range's source window in
// timeline order by seeking the shared reader BACKWARD across a boundary. Audio
// cannot ride that same reader: a single forward pull can't emit samples in the
// reordered timeline order, and the backward per-range seeks would corrupt the
// forward video decode. So audio runs here on its OWN reader — the Windows
// analog of macOS's per-slot `insertTimeRange` + `insertEmptyTimeRange`
// (LetterboxExporter.fillCompositionTrackWithKeptRanges).
//
// For each `AudioSlot` (in timeline order) the pump seeks its reader to the
// slot's source window, copies `copy_frame_count` real PCM frames onto the
// edited timeline, then zero-fills the slot's shortfall (§5.2 silence-fill).
// Slots are emitted in timeline order, so the edited timestamps are monotonic
// even though the SOURCE reads jump around.
//
// Throttling: the MF Sink Writer does NOT set MF_SINK_WRITER_DISABLE_THROTTLING,
// so writing the whole audio track ahead of the video would back-pressure/stall
// the writer. The caller therefore drives the pump INTERLEAVED — `PumpUpTo` is
// called after each written video frame with that frame's edited position, so
// audio is written just behind the video and never races far ahead. `Flush`
// drains the remaining tail (typically the trailing silence) after the loop.
//
// All failures are soft: `Create` returns nullptr (the export then proceeds
// video-only, exactly as before 3b-2b), matching the rest of the pipeline.
namespace clingfy::capture::export_ {

class ReorderAudioPump {
 public:
  // Open a second, independent audio-only source reader on `source_path`
  // (negotiated to 48 kHz stereo int16 PCM, matching the encoder) and
  // precompute the per-slot frame plan from `slots` (built by
  // `clip_planner::AudioSlots`). `channels` is the interleave width (2).
  // `gain` is applied to every copied PCM sample (silence stays zero) so the
  // reorder path honors the user's gain/volume/normalize exactly like the
  // monotonic path. Returns nullptr when the source has no audio stream or the
  // reader/PCM type can't be built.
  static std::unique_ptr<ReorderAudioPump> Create(
      const std::wstring& source_path,
      const std::vector<clip_planner::AudioSlot>& slots,
      std::int64_t sample_rate_hz, std::uint32_t channels,
      const AudioGainStages& gain);

  // Emit every audio packet whose edited start frame is <= `edited_frame_limit`,
  // origin-shifted by `origin_hns` (the first kept video frame's edited PTS — the
  // encoder rebases video but writes audio verbatim, so audio is shifted onto
  // the same zero here) and written to `encoder`. `*audio_packets` is
  // incremented per written packet. Returns an EncoderError on a write failure
  // (the caller cancels + fails the export). Safe to call past the end (no-op).
  std::optional<clingfy::encoding::EncoderError> PumpUpTo(
      std::int64_t edited_frame_limit, std::int64_t origin_hns,
      clingfy::encoding::MfSinkWriterEncoder& encoder,
      std::uint64_t* audio_packets);

  // Drain all remaining audio (final tail, after the video loop). Equivalent to
  // PumpUpTo with an unbounded limit.
  std::optional<clingfy::encoding::EncoderError> Flush(
      std::int64_t origin_hns, clingfy::encoding::MfSinkWriterEncoder& encoder,
      std::uint64_t* audio_packets);

  // True once every slot has been fully emitted.
  bool done() const;

 private:
  ReorderAudioPump() = default;

  // Seek the audio reader so the next ReadSample re-primes at `source_frame`.
  void SeekToFrame(std::int64_t source_frame);

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD audio_index_ = 0;
  std::int64_t sample_rate_ = 0;
  std::uint32_t channels_ = 2;
  AudioGainStages gain_{};
  std::vector<clip_audio::ReorderAudioSlot> plan_;

  // Emission cursor across PumpUpTo calls.
  std::size_t slot_i_ = 0;
  // Frames already emitted (copy + silence) within the current slot.
  std::int64_t emitted_ = 0;
  // The copy phase for the current slot is finished (target reached or the
  // reader hit EOS early — the shortfall then becomes silence).
  bool copy_done_ = false;
  // The reader has been seeked to the current slot's source window.
  bool seeked_ = false;
};

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_REORDER_AUDIO_PUMP_H_
