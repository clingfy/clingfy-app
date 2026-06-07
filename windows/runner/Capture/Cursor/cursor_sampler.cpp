#include "Capture/Cursor/cursor_sampler.h"

#include <algorithm>
#include <chrono>
#include <utility>

#include "Capture/Cursor/cursor_sample_mapper.h"

namespace clingfy::capture {

namespace {

const char* ButtonName(CursorClickHook::Button button) {
  switch (button) {
    case CursorClickHook::Button::kLeft: return "left";
    case CursorClickHook::Button::kRight: return "right";
    case CursorClickHook::Button::kMiddle: return "middle";
  }
  return "left";
}

}  // namespace

CursorSampler::CursorSampler() = default;

CursorSampler::CursorSampler(QpcSource qpc, std::int64_t qpc_frequency)
    : clock_(std::move(qpc), qpc_frequency) {}

CursorSampler::~CursorSampler() { Stop(); }

std::int64_t CursorSampler::NowMs() {
  std::lock_guard<std::mutex> lock(clock_mutex_);
  // ElapsedHns is in 100-ns units; /10000 → ms. Pause-aware.
  return clock_.ElapsedHns() / 10000;
}

std::int64_t CursorSampler::NowMsForTesting() { return NowMs(); }

bool CursorSampler::OpenWriterAndClock(const Config& config, ProbeFn probe,
                                       OriginFn origin) {
  config_ = config;
  probe_ = std::move(probe);
  origin_ = std::move(origin);
  have_prev_ = false;
  last_emit_ms_ = 0;
  paused_.store(false);
  stop_.store(false);

  CursorSidecarWriter::Header header;
  header.schema_version = 1;
  header.sample_rate_hz = config_.sample_rate_hz;
  header.target_type = config_.target_type;
  header.width = config_.width;
  header.height = config_.height;
  header.origin_x = config_.header_origin_x;
  header.origin_y = config_.header_origin_y;
  if (!writer_.Open(config_.sidecar_path, header)) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(clock_mutex_);
    clock_.MarkStart();
  }
  return true;
}

bool CursorSampler::Start(const Config& config, ProbeFn probe, OriginFn origin) {
  if (!OpenWriterAndClock(config, std::move(probe), std::move(origin))) {
    return false;
  }

  // Click hook is additive — a failure to install just means no click lines.
  if (config_.enable_click_hook) {
    click_hook_active_ =
        click_hook_.Start([this]() { return NowMs(); });
  }

  const int hz = config_.sample_rate_hz > 0 ? config_.sample_rate_hz : 60;
  // Clamp the period to >= 1ms so an unexpectedly high rate never busy-spins.
  const auto period = std::chrono::milliseconds(std::max(1, 1000 / hz));
  thread_ = std::thread([this, period]() {
    while (!stop_.load()) {
      if (!paused_.load()) {
        RunOnce();
      }
      std::this_thread::sleep_for(period);
    }
  });
  return true;
}

bool CursorSampler::StartForTesting(const Config& config, ProbeFn probe,
                                    OriginFn origin) {
  // No thread, no hook — the test drives RunOnceForTesting() directly.
  return OpenWriterAndClock(config, std::move(probe), std::move(origin));
}

void CursorSampler::Pause() {
  paused_.store(true);
  {
    std::lock_guard<std::mutex> lock(clock_mutex_);
    clock_.Pause();
  }
  // Flush clicks that fired BEFORE the pause — they carry valid pre-pause
  // timestamps (stamped at fire time, before the clock froze) and belong in the
  // sidecar. Clicks that arrive later, during the pause, are dropped on Resume.
  // (Drain + the writer are each mutex-guarded, so this is safe even if the
  // sampler thread is mid-tick.)
  if (click_hook_active_) {
    DrainAndWriteClicks();
  }
}

void CursorSampler::Resume() {
  {
    std::lock_guard<std::mutex> lock(clock_mutex_);
    clock_.Resume();
  }
  // Drop anything the hook enqueued during the pause before resuming.
  click_hook_.Drain();
  paused_.store(false);
}

void CursorSampler::Stop() {
  stop_.store(true);
  if (thread_.joinable()) {
    thread_.join();
  }
  click_hook_.Stop();
  click_hook_active_ = false;
  // Write any clicks captured between the last tick and stop, then close.
  if (writer_.is_open()) {
    DrainAndWriteClicks();
    writer_.Close();
  }
}

void CursorSampler::DrainAndWriteClicks() {
  auto events = click_hook_.Drain();
  for (const auto& event : events) {
    writer_.WriteClick(event.t_ms, event.screen_x, event.screen_y,
                       ButtonName(event.button), event.down);
  }
}

bool CursorSampler::RunOnce() {
  if (paused_.load()) {
    return false;
  }
  // Clicks first so they interleave roughly chronologically with this tick's
  // sample (the reader sorts by tMs regardless).
  if (click_hook_active_) {
    DrainAndWriteClicks();
  }

  const Probe probe = probe_ ? probe_() : Probe{};
  std::int32_t origin_x = config_.header_origin_x;
  std::int32_t origin_y = config_.header_origin_y;
  if (origin_) {
    origin_(origin_x, origin_y);
  }
  const CursorLocalPoint local = MapScreenToCaptureLocal(
      probe.screen_x, probe.screen_y, origin_x, origin_y, config_.width,
      config_.height);
  const bool visible = probe.present && local.visible;

  const std::int64_t now = NowMs();
  if (!ShouldEmitCursorSample(have_prev_, prev_x_, prev_y_, prev_visible_,
                              local.x, local.y, visible, now - last_emit_ms_,
                              config_.heartbeat_ms)) {
    return false;
  }
  writer_.WriteSample(now, probe.screen_x, probe.screen_y, local.x, local.y,
                      visible);
  have_prev_ = true;
  prev_x_ = local.x;
  prev_y_ = local.y;
  prev_visible_ = visible;
  last_emit_ms_ = now;
  return true;
}

bool CursorSampler::RunOnceForTesting() { return RunOnce(); }

bool CursorSampler::sidecar_open() const { return writer_.is_open(); }

}  // namespace clingfy::capture
