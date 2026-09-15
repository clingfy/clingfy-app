#include "Audio/EchoCancel/mic_echo_canceller.h"

#include <algorithm>
#include <cmath>

namespace clingfy::audio::echo {

namespace {

int SamplesFor(double seconds) {
  return static_cast<int>(std::lround(seconds * kSampleRate));
}

}  // namespace

std::vector<float> MovingRms(const std::vector<float>& x) {
  const size_t n = x.size();
  std::vector<float> out(n, 0.0f);
  if (n == 0) {
    return out;
  }
  const size_t w = static_cast<size_t>(
      std::max(1, SamplesFor(kEnvelopeWindowSeconds)));
  double running = 0.0;
  for (size_t i = 0; i < n; ++i) {
    running += static_cast<double>(x[i]) * x[i];
    if (i >= w) {
      running -= static_cast<double>(x[i - w]) * x[i - w];
    }
    const double count = static_cast<double>(std::min(i + 1, w));
    // Float cancellation can drift `running` a hair below zero; clamp before
    // the sqrt so the envelope never becomes NaN and poisons everything
    // downstream.
    out[i] = static_cast<float>(std::sqrt(std::max(running, 0.0) / count));
  }
  return out;
}

float Percentile(std::vector<float> values, double q) {
  if (values.empty()) {
    return 0.0f;
  }
  std::sort(values.begin(), values.end());
  const double clamped = std::min(1.0, std::max(0.0, q));
  const double pos = clamped * static_cast<double>(values.size() - 1);
  const size_t lo = static_cast<size_t>(std::floor(pos));
  const size_t hi = static_cast<size_t>(std::ceil(pos));
  if (lo == hi) {
    return values[lo];
  }
  const float frac = static_cast<float>(pos - static_cast<double>(lo));
  return values[lo] + (values[hi] - values[lo]) * frac;
}

std::vector<float> DecimateZeroMean(const std::vector<float>& x, int factor) {
  std::vector<float> out;
  if (factor <= 1) {
    out = x;
  } else {
    const size_t out_count = x.size() / static_cast<size_t>(factor);
    if (out_count == 0) {
      return {};
    }
    out.resize(out_count, 0.0f);
    const float inv = 1.0f / static_cast<float>(factor);
    for (size_t i = 0; i < out_count; ++i) {
      double s = 0.0;
      for (int k = 0; k < factor; ++k) {
        s += x[i * static_cast<size_t>(factor) + static_cast<size_t>(k)];
      }
      out[i] = static_cast<float>(s) * inv;
    }
  }
  if (out.empty()) {
    return out;
  }
  double mean = 0.0;
  for (const float v : out) {
    mean += v;
  }
  mean /= static_cast<double>(out.size());
  for (float& v : out) {
    v -= static_cast<float>(mean);
  }
  return out;
}

DelayEstimate EstimateDelay(const std::vector<float>& mic,
                            const std::vector<float>& system) {
  const int m = kDelaySearchDecimation;
  const std::vector<float> a = DecimateZeroMean(mic, m);
  const std::vector<float> b = DecimateZeroMean(system, m);
  const int len = static_cast<int>(std::min(a.size(), b.size()));
  if (len <= 1) {
    return {};
  }

  // Cap the search span to half the data so the window guard can still pass on
  // a short clip, then floor out implausibly small lags.
  const int max_lag =
      std::min(static_cast<int>(kMaxDelaySeconds * kSampleRate / m),
               (len - 1) / 2);
  const int min_lag = static_cast<int>(kMinDelaySeconds * kSampleRate / m);
  if (max_lag <= min_lag) {
    return {};
  }
  const int win = std::max(
      2 * max_lag + 2,
      static_cast<int>(kDetectionWindowSeconds * kSampleRate / m));
  const int hop = std::max(1, win / 2);

  std::vector<int> peak_lags;
  std::vector<float> peak_corrs;

  for (int start = 0; start < len;) {
    const int end = std::min(start + win, len);
    if (end - start > max_lag + 1) {
      float window_best = 0.0f;
      int window_lag = 0;
      for (int lag = -max_lag; lag <= max_lag; ++lag) {
        if (std::abs(lag) < min_lag) {
          continue;
        }
        const int i_lo = std::max(start, lag);      // need i - lag >= 0
        const int i_hi = std::min(end, len + lag);  // need i - lag < len
        const int count = i_hi - i_lo;
        if (count <= 1) {
          continue;
        }
        double dot = 0.0;
        double sq_a = 0.0;
        double sq_b = 0.0;
        for (int i = i_lo; i < i_hi; ++i) {
          const double av = a[static_cast<size_t>(i)];
          const double bv = b[static_cast<size_t>(i - lag)];
          dot += av * bv;
          sq_a += av * av;
          sq_b += bv * bv;
        }
        // Require the reference window to be audibly present — correlating
        // against silence produces noise-driven peaks at arbitrary lags.
        const double ref_rms = std::sqrt(sq_b / count);
        if (ref_rms < kReferencePresentFloor) {
          continue;
        }
        const double denom = std::max(std::sqrt(sq_a * sq_b), 1e-9);
        const float c = static_cast<float>(dot / denom);
        if (std::abs(c) > std::abs(window_best)) {
          window_best = c;
          window_lag = lag;
        }
      }
      if (std::abs(window_best) >= kGateCorrelation) {
        peak_lags.push_back(window_lag);
        peak_corrs.push_back(window_best);
      }
    }
    if (end >= len) {
      break;
    }
    start += hop;
  }

  if (static_cast<int>(peak_lags.size()) < kMinConsensusWindows) {
    return {};
  }

  // Largest cluster of agreeing lags. A coincidental correlation is a lone
  // outlier; real bleed repeats at the same lag across windows.
  const int tolerance =
      static_cast<int>(kClusterToleranceSeconds * kSampleRate / m);
  std::vector<int> best_cluster;
  float best_corr = 0.0f;
  for (size_t i = 0; i < peak_lags.size(); ++i) {
    std::vector<int> members;
    float strongest = 0.0f;
    for (size_t j = 0; j < peak_lags.size(); ++j) {
      if (std::abs(peak_lags[j] - peak_lags[i]) <= tolerance) {
        members.push_back(peak_lags[j]);
        if (std::abs(peak_corrs[j]) > std::abs(strongest)) {
          strongest = peak_corrs[j];
        }
      }
    }
    if (members.size() > best_cluster.size()) {
      best_cluster = std::move(members);
      best_corr = strongest;
    }
  }
  if (static_cast<int>(best_cluster.size()) < kMinConsensusWindows) {
    return {};
  }
  std::sort(best_cluster.begin(), best_cluster.end());
  const int median = best_cluster[best_cluster.size() / 2];
  return DelayEstimate{median * m, best_corr};
}

std::vector<float> AlignedReference(const std::vector<float>& system,
                                    int delay_samples, size_t n) {
  const int preroll = SamplesFor(kPrerollSeconds);
  const int offset = preroll - delay_samples;
  std::vector<float> reference(n, 0.0f);
  const int m = static_cast<int>(std::min(n, system.size()));
  for (size_t i = 0; i < n; ++i) {
    const int j = static_cast<int>(i) + offset;
    if (j >= 0 && j < m) {
      reference[i] = system[static_cast<size_t>(j)];
    }
  }
  return reference;
}

std::vector<float> BleedAlignedReference(const std::vector<float>& system,
                                         int delay_samples, size_t n) {
  std::vector<float> out(n, 0.0f);
  const int m = static_cast<int>(std::min(n, system.size()));
  for (size_t i = 0; i < n; ++i) {
    const int j = static_cast<int>(i) - delay_samples;
    if (j >= 0 && j < m) {
      out[i] = system[static_cast<size_t>(j)];
    }
  }
  return out;
}

std::vector<bool> NearEndVoiceMask(const std::vector<float>& mic,
                                   const std::vector<float>& reference,
                                   const std::vector<float>& mic_env,
                                   float voice_floor) {
  const size_t n = mic.size();
  std::vector<bool> mask(n, false);
  if (n == 0 || reference.size() < n || mic_env.size() < n) {
    return mask;
  }
  const size_t w = static_cast<size_t>(
      std::max(1, SamplesFor(kVoiceCorrelationWindowSeconds)));
  for (size_t s = 0; s < n;) {
    const size_t e = std::min(s + w, n);
    const double k = static_cast<double>(e - s);
    double sm = 0.0, sr = 0.0, smm = 0.0, srr = 0.0, smr = 0.0;
    for (size_t i = s; i < e; ++i) {
      const double mv = mic[i];
      const double rv = reference[i];
      sm += mv;
      sr += rv;
      smm += mv * mv;
      srr += rv * rv;
      smr += mv * rv;
    }
    const double cov = smr - sm * sr / k;
    const double var_mic = smm - sm * sm / k;
    const double var_ref = srr - sr * sr / k;
    const double den = std::sqrt(std::max(var_mic, 0.0) * std::max(var_ref, 0.0));
    const double corr = den > 1e-12 ? std::abs(cov / den) : 0.0;
    if (corr < kVoiceCorrelationThreshold) {
      for (size_t i = s; i < e; ++i) {
        if (mic_env[i] > voice_floor) {
          mask[i] = true;
        }
      }
    }
    s = e;
  }
  return mask;
}

std::vector<float> NlmsDoubleTalk(const std::vector<float>& desired,
                                  const std::vector<float>& reference,
                                  const std::vector<bool>& freeze) {
  const size_t n = desired.size();
  const size_t taps = static_cast<size_t>(kFilterTaps);
  if (n == 0 || reference.size() < n) {
    return desired;
  }

  // Left-pad the reference with taps-1 zeros so the causal window
  // ref_pad[i .. i+taps) is always valid and zero-filled before sample 0.
  std::vector<float> ref_pad(n + taps - 1, 0.0f);
  for (size_t i = 0; i < n; ++i) {
    ref_pad[i + taps - 1] = reference[i];
  }

  std::vector<float> weights(taps, 0.0f);
  std::vector<float> out(n, 0.0f);
  double energy = 0.0;

  for (size_t i = 0; i < n; ++i) {
    const float* window = ref_pad.data() + i;  // oldest -> newest
    // Sliding energy: add the newest sample, drop the one that left.
    const double newest = ref_pad[i + taps - 1];
    const double leaving = i == 0 ? 0.0 : ref_pad[i - 1];
    energy += newest * newest - leaving * leaving;

    double y = 0.0;
    for (size_t t = 0; t < taps; ++t) {
      y += static_cast<double>(weights[t]) * window[t];
    }
    const double e = static_cast<double>(desired[i]) - y;
    out[i] = static_cast<float>(e);

    if (i < freeze.size() && freeze[i]) {
      continue;  // near-end voice or silent reference: hold the filter
    }
    const double scale =
        kStepSize * e / (std::max(energy, 0.0) + kRegularization);
    for (size_t t = 0; t < taps; ++t) {
      weights[t] += static_cast<float>(scale * window[t]);
    }
  }
  return out;
}

std::vector<float> SystemPresenceBlend(const std::vector<float>& raw,
                                       const std::vector<float>& cleaned,
                                       const std::vector<float>& mic_env,
                                       const std::vector<float>& ref_env,
                                       const std::vector<bool>& voice) {
  const size_t n = raw.size();
  if (cleaned.size() != n || mic_env.size() != n || ref_env.size() != n) {
    return cleaned;
  }

  // System-presence mask: active envelope, dilated backward (envelope rise
  // time) and held forward (bridges intra-speech gaps so the blend does not
  // flap raw/cleaned inside one system sentence — each flap leaks a bleed edge).
  std::vector<bool> present(n, false);
  const int hold = static_cast<int>(kSystemHoldSeconds * kSampleRate);
  const int backfill = static_cast<int>(kSystemBackfillSeconds * kSampleRate);
  int last_active = -hold - 1;
  for (size_t i = 0; i < n; ++i) {
    if (ref_env[i] > kReferencePresentFloor) {
      last_active = static_cast<int>(i);
    }
    present[i] = (static_cast<int>(i) - last_active) <= hold;
  }
  int next_active = static_cast<int>(n) + backfill + 1;
  for (int i = static_cast<int>(n) - 1; i >= 0; --i) {
    if (ref_env[static_cast<size_t>(i)] > kReferencePresentFloor) {
      next_active = i;
    }
    if ((next_active - i) <= backfill) {
      present[static_cast<size_t>(i)] = true;
    }
  }

  const float fast =
      static_cast<float>(1.0 - std::exp(-1.0 / (kBlendFastSeconds * kSampleRate)));
  const float slow =
      static_cast<float>(1.0 - std::exp(-1.0 / (kBlendSlowSeconds * kSampleRate)));
  const float duck_floor = std::pow(10.0f, kPauseDuckDb / 20.0f);

  std::vector<float> out(n, 0.0f);
  float gain = 1.0f;  // 1 -> raw mic, 0 -> cleaned mic
  float duck = 1.0f;  // 1 -> no duck, duck_floor -> full duck
  for (size_t i = 0; i < n; ++i) {
    const bool is_voice = i < voice.size() && voice[i];
    const bool use_cleaned = present[i] && !is_voice;
    const float target = use_cleaned ? 0.0f : 1.0f;
    // FAST into cleaned (bleed must not leak at system onsets), slow to raw.
    const float coeff = target < gain ? fast : slow;
    gain += coeff * (target - gain);

    const bool bleed_only =
        present[i] && mic_env[i] < kPauseDuckMicToRefRatio * ref_env[i];
    const float duck_target = bleed_only ? duck_floor : 1.0f;
    // Engage slowly, release FAST — a voice onset must never be swallowed.
    const float duck_coeff = duck_target < duck ? slow : fast;
    duck += duck_coeff * (duck_target - duck);

    out[i] = gain * raw[i] + (1.0f - gain) * (cleaned[i] * duck);
  }
  return out;
}

namespace {

// Normalized correlation at one full-rate lag, measured on the decimated
// signals. Diagnostics only — used to report the reduction.
float CorrelationAtDelay(const std::vector<float>& a,
                         const std::vector<float>& b, int delay_samples) {
  const int m = kDelaySearchDecimation;
  const std::vector<float> ad = DecimateZeroMean(a, m);
  const std::vector<float> bd = DecimateZeroMean(b, m);
  const int len = static_cast<int>(std::min(ad.size(), bd.size()));
  if (len <= 1) {
    return 0.0f;
  }
  const int lag = static_cast<int>(std::lround(
      static_cast<double>(delay_samples) / m));
  if (std::abs(lag) >= len) {
    return 0.0f;
  }
  // The norms must cover the SAME overlap slice as the dot product, or the
  // correlation is under-normalized by the excluded |lag| samples.
  const int count = len - std::abs(lag);
  const int a_off = lag >= 0 ? lag : 0;
  const int b_off = lag >= 0 ? 0 : -lag;
  double dot = 0.0, sq_a = 0.0, sq_b = 0.0;
  for (int i = 0; i < count; ++i) {
    const double av = ad[static_cast<size_t>(a_off + i)];
    const double bv = bd[static_cast<size_t>(b_off + i)];
    dot += av * bv;
    sq_a += av * av;
    sq_b += bv * bv;
  }
  return static_cast<float>(dot / std::max(std::sqrt(sq_a * sq_b), 1e-9));
}

}  // namespace

EchoCancelResult CancelEcho(const std::vector<float>& mic,
                            const std::vector<float>& system) {
  EchoCancelResult result;
  const size_t n = std::min(mic.size(), system.size());
  if (n < static_cast<size_t>(kMinSamples)) {
    result.mic = mic;  // too short to estimate anything
    return result;
  }
  const std::vector<float> mic_n(mic.begin(), mic.begin() + n);
  const std::vector<float> system_n(system.begin(), system.begin() + n);

  // 1. Signed bleed delay + peak correlation, on the STRONGEST window so loud
  //    speech elsewhere cannot average the bleed below the gate.
  const DelayEstimate delay = EstimateDelay(mic_n, system_n);
  result.bleed_correlation = delay.correlation;
  result.delay_ms = static_cast<double>(delay.samples) / kSampleRate * 1000.0;
  if (std::abs(delay.correlation) < kGateCorrelation) {
    // No measurable bleed — headphones, or no system audio. Leave the mic
    // EXACTLY as recorded; this is the common case and must be bit-exact.
    result.mic = mic;
    return result;
  }

  // 2-3. Delay-aligned reference and envelopes.
  const std::vector<float> reference =
      AlignedReference(system_n, delay.samples, n);
  const std::vector<float> mic_env = MovingRms(mic_n);
  const std::vector<float> ref_env = MovingRms(reference);

  // 4. Near-end voice mask, correlated against the BLEED-aligned system so a
  //    pure-bleed window reads as bleed whatever the system's spectrum.
  const std::vector<float> voice_reference =
      BleedAlignedReference(system_n, delay.samples, n);
  // Self-scaling energy gate. A fixed floor sat above the entire voice on a
  // quiet recording, so the mask never fired and the cleaned path ran over —
  // and distorted — the user's voice. Capped at kVoiceMicFloor so a loud
  // recording is never gated more loosely than before.
  const float speaking_level = Percentile(mic_env, kVoiceSpeakingPercentile);
  const float effective_voice_floor =
      std::min(kVoiceMicFloor,
               std::max(kVoiceMicNoiseFloor, kVoiceMicFraction * speaking_level));
  const std::vector<bool> voice =
      NearEndVoiceMask(mic_n, voice_reference, mic_env, effective_voice_floor);

  // 5. NLMS, frozen on near-end voice AND on a near-silent reference. Freezing
  //    on voice keeps the filter a clean bleed model. Freezing on silence is a
  //    stability guard: the normalized update has a tiny regularizer, so
  //    adapting on a near-zero reference drives the weights into a misadjusted
  //    state that then OVER-predicts in a later loud pause, producing
  //    out-of-scale bursts. There is nothing to learn from silence.
  std::vector<bool> adaptation_freeze = voice;
  for (size_t i = 0; i < n; ++i) {
    if (ref_env[i] < kReferencePresentFloor) {
      adaptation_freeze[i] = true;
    }
  }
  const std::vector<float> cleaned =
      NlmsDoubleTalk(mic_n, reference, adaptation_freeze);

  // 6. Blend by system presence (see SystemPresenceBlend).
  std::vector<float> blended =
      SystemPresenceBlend(mic_n, cleaned, mic_env, ref_env, voice);

  // Measure the residual the SAME way before and after, so the ratio is a
  // faithful reduction rather than a comparison of two different statistics.
  const float residual_before =
      CorrelationAtDelay(mic_n, system_n, delay.samples);
  const float residual_after =
      CorrelationAtDelay(blended, system_n, delay.samples);
  result.reduction_db =
      20.0 * std::log10(std::abs(residual_after) /
                            std::max(std::abs(residual_before), 1e-6f) +
                        1e-9);

  // Anything the caller trimmed off the end (mic longer than system) is kept
  // as recorded — there is no reference there to cancel against.
  result.mic = std::move(blended);
  if (mic.size() > n) {
    result.mic.insert(result.mic.end(), mic.begin() + n, mic.end());
  }
  result.applied = true;
  return result;
}

}  // namespace clingfy::audio::echo
