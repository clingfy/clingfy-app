#ifndef RUNNER_AUDIO_WASAPI_STREAM_FORMAT_H_
#define RUNNER_AUDIO_WASAPI_STREAM_FORMAT_H_

#include <windows.h>

#include <audioclient.h>
#include <mmreg.h>

#include "Audio/audio_format.h"

// Opening a WASAPI shared-mode stream in the pipeline's canonical format,
// letting the audio engine resample when the endpoint disagrees.
//
// WHY THIS EXISTS. The whole pipeline is hardcoded to 48 kHz float32 stereo
// (`kPipelineSampleRateHz` / `kPipelineChannelCount`): the mixer, the int16
// conversion feeding the AAC encoder, and the preview renderer's frame math
// all assume it. Both WASAPI edges used to hand the endpoint's OWN mix format
// straight back to `Initialize`, so a device running at 44.1 kHz — common on
// USB interfaces and anything a user has touched in the Sound control panel —
// was simply refused. Capture said so out loud (a MIC_OPEN_FAILED toast); the
// preview renderer just returned null and played silent video with no notice
// at all.
//
// Shared mode already contains a resampler. `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`
// turns it on, and it only engages when the format handed to `Initialize`
// DIFFERS from the mix format — which is the load-bearing half. Adding the flag
// while still passing `mix_format` is a no-op on every machine.
//
// This file is separate from `audio_format.h` on purpose: that header
// forward-declares WAVEFORMATEX precisely so the mixer and its tests never
// pull in Win32. Building a WAVEFORMATEXTENSIBLE needs mmreg.h, so it lives
// here, next to the only two callers that already include it.
namespace clingfy::audio {

// The pipeline's canonical stream format: 48 kHz, stereo, 32-bit IEEE float,
// front-left/front-right. Pure — it reads nothing from the system — so its
// field values are asserted directly in the unit tests.
WAVEFORMATEXTENSIBLE CanonicalPipelineFormat();

struct SharedStreamInit {
  HRESULT hr = E_FAIL;
  // True when the endpoint disagreed with the pipeline and the audio engine
  // is converting for us. Purely informational — for logging and tests — since
  // the APP-side format is canonical either way.
  bool converted = false;
};

// Initialize `client` for shared-mode streaming in the canonical format.
//
// Two paths, and the distinction matters:
//   * the endpoint ALREADY matches the pipeline — initialize with its own mix
//     format exactly as before this helper existed, so the overwhelmingly
//     common case is byte-identical to the old behaviour;
//   * it does not — initialize with the canonical format plus
//     AUTOCONVERTPCM | SRC_DEFAULT_QUALITY, and let the engine resample.
//     SRC_DEFAULT_QUALITY matters: without it the engine uses a low-quality
//     linear-interpolation resampler.
//
// NO FALLBACK TO THE MIX FORMAT ON FAILURE, deliberately. If the conversion
// path is refused, retrying with the endpoint's own format would hand the
// pipeline 44.1 kHz data that every downstream consumer would read as 48 kHz —
// silently wrong audio, pitched and drifting. That is precisely what the
// original hard rejection existed to prevent, so a refusal stays a refusal and
// the caller keeps its existing error path. (A failed `Initialize` also poisons
// the client: re-initializing one returns AUDCLNT_E_ALREADY_INITIALIZED, so a
// retry would need a fresh Activate anyway.)
//
// `base_flags` is OR-ed into whatever this adds — callers pass
// AUDCLNT_STREAMFLAGS_EVENTCALLBACK, and capture adds
// AUDCLNT_STREAMFLAGS_LOOPBACK for system audio.
SharedStreamInit InitializeSharedStream(IAudioClient* client, DWORD base_flags,
                                        REFERENCE_TIME buffer_duration_hns,
                                        const WAVEFORMATEX* mix_format);

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_WASAPI_STREAM_FORMAT_H_
