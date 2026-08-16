#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_SAMPLER_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_SAMPLER_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "Capture/Cursor/cursor_click_hook.h"
#include "Capture/Cursor/cursor_sidecar_writer.h"
#include "Capture/recording_clock.h"

// Phase 8.1 — cursor sampler. Polls the cursor at ~60 Hz on a dedicated thread,
// maps each position into capture-local px (per target mode), and streams
// samples + clicks into a `cursor.jsonl` sidecar.
//
// Threading: the sampler owns its OWN pause-aware `RecordingClock` (driven by the
// engine via MarkStart/Pause/Resume) so the sampler thread and the click-hook
// thread can read recording-time `tMs` under the sampler's own small mutex —
// never racing the engine's clock. The probe (cursor position) and origin
// (capture-region top-left, which the window mode recomputes per tick via DWM)
// are injected functors so the engine owns all Win32 and this header stays
// Win32-free and unit-testable with fakes.
namespace clingfy::capture {

// Declared, not included: the cache needs <windows.h> for HCURSOR and this
// header is deliberately Win32-free so the sampler can be tested with fakes.
class CursorSpriteCache;

class CursorSampler {
 public:
  // Cursor probe result: screen (virtual-desktop physical) px + whether the
  // cursor is currently showing.
  struct Probe {
    std::int32_t screen_x = 0;
    std::int32_t screen_y = 0;
    bool present = false;
    // The live cursor SHAPE handle (an HCURSOR), kept as void* so this
    // header stays Win32-free and unit-testable with fakes. GetCursorInfo
    // already fills it in; it used to be read and thrown away, which is why
    // every export drew the same arrow. Null = no shape this tick.
    void* cursor_handle = nullptr;
  };
  using ProbeFn = std::function<Probe()>;
  // Resolve the capture-region top-left in screen px. Display/area pass a
  // constant; window recomputes from DWM each tick (the window may move).
  using OriginFn = std::function<void(std::int32_t& origin_x,
                                      std::int32_t& origin_y)>;

  struct Config {
    std::string sidecar_path;
    std::string target_type = "display";  // header
    std::int32_t width = 0;                // capture dims (mapping bounds + header)
    std::int32_t height = 0;
    std::int32_t header_origin_x = 0;      // origin snapshot for the header line
    std::int32_t header_origin_y = 0;
    int sample_rate_hz = 60;
    std::int64_t heartbeat_ms = 1000;
    bool enable_click_hook = true;
  };

  CursorSampler();
  // Test ctor: inject a fake QPC source + frequency for the internal clock.
  CursorSampler(QpcSource qpc, std::int64_t qpc_frequency);
  ~CursorSampler();

  CursorSampler(const CursorSampler&) = delete;
  CursorSampler& operator=(const CursorSampler&) = delete;

  // Open the sidecar (writes the header), MarkStart the clock, install the click
  // hook (best-effort), and spawn the 60 Hz sampling thread. Returns false ONLY
  // when the sidecar could not be opened — the caller then keeps the Phase 7
  // cursor-on fallback. A click-hook failure is non-fatal (clicks absent).
  bool Start(const Config& config, ProbeFn probe, OriginFn origin);

  // Pause / resume sampling. Forwarded from the engine alongside its own clock so
  // sample `tMs` excludes paused time and no samples/clicks are recorded while
  // paused.
  void Pause();
  void Resume();

  // Stop the thread, flush + close the sidecar, stop the click hook. Idempotent.
  void Stop();

  bool sidecar_open() const;

  // --- Test seams (no thread / no hook) ----------------------------------
  // Open the sidecar + clock without spawning the thread or installing the hook,
  // so a test can drive ticks deterministically.
  bool StartForTesting(const Config& config, ProbeFn probe, OriginFn origin);
  // Run a single sampling tick synchronously. Returns true if a sample was
  // emitted. No-op (returns false) while paused.
  bool RunOnceForTesting();
  // Current pause-aware recording-time ms (what samples/clicks are stamped with).
  std::int64_t NowMsForTesting();

 private:
  bool OpenWriterAndClock(const Config& config, ProbeFn probe, OriginFn origin);
  bool RunOnce();
  std::int64_t NowMs();
  void DrainAndWriteClicks();

  mutable std::mutex clock_mutex_;
  RecordingClock clock_;

  CursorSidecarWriter writer_;
  // Rasterized cursor shapes, deduped by handle. Held by pointer to keep
  // <windows.h> out of this header; created lazily on the first shaped sample
  // so a fake-probe test never touches GDI.
  std::unique_ptr<CursorSpriteCache> sprite_cache_;
  CursorClickHook click_hook_;
  bool click_hook_active_ = false;

  ProbeFn probe_;
  OriginFn origin_;
  Config config_;

  std::thread thread_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> paused_{false};

  // Dedup + heartbeat state (touched only by the sampling thread / test tick).
  bool have_prev_ = false;
  std::int32_t prev_x_ = 0;
  std::int32_t prev_y_ = 0;
  bool prev_visible_ = false;
  std::int64_t last_emit_ms_ = 0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_SAMPLER_H_
