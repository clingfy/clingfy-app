// Windows Phase 5 POC — Stage 1B (video-only)
//                     + Stage 1C (video + cursor)
//                     + Stage 1D (1C + seek slider + 30 s measurement)
//
// One opt-in standalone Win32 GUI executable. Three modes, decided
// purely by the CLI arguments at startup:
//
//   * --video=PATH only (or just `CLINGFY_POC_VIDEO`):
//     Stage 1B behavior. Load the MP4 via MediaPlayer frame-server,
//     CopyFrameToVideoSurface onto an offscreen D3D11 texture, D2D
//     blit (letterboxed) onto the swap-chain back buffer, Present.
//     STAGE1B_STATS to stderr on close.
//
//   * --video=PATH plus --cursor=PATH (or `CLINGFY_POC_CURSOR`):
//     Stage 1C behavior — same pipeline, plus per-frame
//     cursor / click composition. cursor.jsonl is hand-authored,
//     one JSON object per line:
//         ts_us         video-timeline timestamp (microseconds)
//         x, y          cursor position in VIDEO PIXEL coordinates
//         button_state  0 = up sample, non-zero = mouse-down
//         monitor_id    integer, currently unused
//     A click within ±500 ms of playback ts triggers a zoom-in to
//     `kZoomFactorDefault` centered on the click. After the
//     `kZoomMinOnSeconds` hold expires it decays back to 1.0×.
//     A radial highlight is drawn at the cursor position with
//     alpha tied to zoom intensity. STAGE1C_STATS (four bucket
//     lines: total / copy / render / present) to stderr on close.
//
//   * Either of the above, AND the 30-second measurement window
//     automatically completes:
//     Stage 1D behavior. Same stderr output as 1B / 1C plus a
//     Markdown summary at `build/windows-poc/stage1d_result.md`
//     with:
//        * header (UTC timestamp + branch)
//        * system info (Windows build, GPU description, video
//          natural size, source FPS proxy)
//        * per-bucket stats (median / p99 / max / dropped)
//        * seek samples (target ts, latency, source = user/programmed)
//        * verdict line vs the design-doc bar (median ≤ 16 ms,
//          p99 ≤ 25 ms total)
//     A native Win32 trackbar at the bottom of the window lets the
//     user scrub. Two programmed seeks fire automatically inside
//     the measurement window (at elapsed = 7 s and 22 s) so the
//     report always has at least two seek samples even with no
//     human input.
//
// What this is NOT: production code. Not linked into the main
// Flutter app. Does not touch the bridge contract or any production
// preview surface. The cmake option BUILD_LIVE_COMPOSITOR_POC
// defaults to OFF, so `flutter build windows` ignores this file
// entirely. No production previewOpen / previewPlay / previewSeekTo
// touched. No Dart bridge contract additions. No real cursor sidecar
// capture (hand-authored JSONL only). No Flutter Texture bridge —
// that is Stage 2's whole job.
//
// All zoom timing / intensity constants come from
// `preview/zoom_easing_constants.h` (the Step 0 #96 header).
// Never hard-code a zoom magnitude or smoother strength here.
//
// Threading note: VideoFrameAvailable fires on a WinRT thread-pool
// worker. We do the whole render-and-present on that worker thread.
// That requires:
//   * D3D11 device with ID3D11Multithread::SetMultithreadProtected(TRUE)
//   * D2D factory created with D2D1_FACTORY_TYPE_MULTI_THREADED
// IDXGISwapChain1::Present is documented as callable from any thread.
//
// Run:
//   build/windows-poc/runner/preview/Debug/mediaplayer_frame_server_demo.exe ^
//     --video="C:\path\to\recording.mp4" ^
//     --cursor="C:\path\to\cursor.jsonl"

#define WIN32_LEAN_AND_MEAN
// NOMINMAX is set via target_compile_definitions in the POC CMakeLists.

#include <windows.h>
#include <winternl.h>  // RTL_OSVERSIONINFOW + NTSTATUS for WindowsVersionString
#include <commctrl.h>
#include <shellapi.h>
#include <inspectable.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <wrl/client.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Playback.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "preview/frame_timing.h"
#include "preview/preview_compositor.h"
#include "preview/zoom_easing_constants.h"

namespace {

using Microsoft::WRL::ComPtr;

namespace winrt_foundation = winrt::Windows::Foundation;
namespace winrt_dxd3d = winrt::Windows::Graphics::DirectX::Direct3D11;
namespace winrt_media = winrt::Windows::Media::Core;
namespace winrt_playback = winrt::Windows::Media::Playback;

constexpr wchar_t kWindowClassName[] = L"ClingfyMediaPlayerFrameServerPOC";
constexpr wchar_t kWindowTitle[] =
    L"Clingfy Live Compositor POC — MediaPlayer frame-server";
constexpr int kDefaultWidth = 1280;
constexpr int kDefaultHeight = 720;

// kClickLookupWindowUs + kHighlightRadiusPx live in preview_compositor.h
// (the shared static lib). The HWND demo and the Flutter texture bridge
// both consume the same values.
using clingfy::preview::ZoomState;

// --- Stage 1D constants -----------------------------------------------
// Pixel reservation at the bottom of the client area for the Win32
// trackbar control. Slider sits inside, video dest rect is computed
// against (client_height - kSliderStripPx).
constexpr int kSliderStripPx = 36;
// Slider range: 0..1000 = 0..100.0 % of NaturalDuration. 0.1 %
// resolution is plenty for a scrub UI; the actual MediaPlayer seek
// target is computed in TimeSpan ticks so the round-trip stays exact
// at the API boundary.
constexpr int kSliderRange = 1000;
// Timer that polls MediaPlayer.PlaybackSession.Position and updates the
// trackbar thumb to match. UI thread. 100 ms feels live without
// flooding the window queue.
constexpr UINT_PTR kPositionPollTimerId = 1;
constexpr UINT kPositionPollPeriodMs = 100;
// Stage 1D measurement window. Frames inside [first_frame_qpc,
// first_frame_qpc + kMeasurementWindowSeconds] count toward the
// per-bucket stats; frames outside still render but are ignored by
// the collectors.
constexpr double kMeasurementWindowSeconds = 30.0;
// Programmed seek schedule, in seconds since measurement start. Each
// fires exactly once; the latency is measured against the next
// VideoFrameAvailable. Picked at 7 s and 22 s so the report always has
// at least two seek samples even if the user never touches the slider
// during the run.
constexpr double kProgrammedSeek1Seconds = 7.0;
constexpr double kProgrammedSeek2Seconds = 22.0;
// Where the Stage 1D markdown artifact is written. Relative to the
// current working directory at exe launch — typically the repo root
// when run via the documented `build/windows-poc/...` path.
constexpr wchar_t kStage1dResultPath[] =
    L"build\\windows-poc\\stage1d_result.md";

// Design-doc Stage-1 pass bar (the verdict line in the artifact
// compares against these). 1080p, total bucket.
constexpr double kPassBarMedianMs = 16.0;
constexpr double kPassBarP99Ms = 25.0;

// ZoomState / StepZoomSmoother live in preview_compositor.{h,cpp} (the
// preview_poc_common static lib), shared with the Flutter texture bridge.
//
// The CURSOR PARSER does not. This demo consumes the Stage-1 POC format
// (`{"ts_us":N,"x":N,"y":N,"button_state":N}`), which the shipping recorder
// has never written — it emits the `tMs` sidecar that `ParseCursorSidecar`
// reads. Keeping the POC parser here, next to the fixtures that use it, is
// what let the production preview move to the real reader; sharing it is what
// made the production preview silently parse zero events on every real
// project. Do not promote it back into the shared lib.
capture::CursorSidecarData LoadPocCursorJsonl(const std::wstring& path) {
  capture::CursorSidecarData out;
  std::ifstream in(path);
  if (!in.is_open()) return out;
  std::string line;
  while (std::getline(in, line)) {
    const auto brace = line.find('{');
    if (brace == std::string::npos) continue;
    auto num = [&line](const char* key, long long* dest) {
      const std::string needle = std::string("\"") + key + "\"";
      const auto k = line.find(needle);
      if (k == std::string::npos) return false;
      const auto colon = line.find(':', k + needle.size());
      if (colon == std::string::npos) return false;
      *dest = std::strtoll(line.c_str() + colon + 1, nullptr, 10);
      return true;
    };
    long long ts_us = 0, x = 0, y = 0, button = 0;
    if (!num("ts_us", &ts_us) || !num("x", &x) || !num("y", &y)) continue;
    capture::CursorSidecarSample sample;
    sample.t_ms = ts_us / 1000;
    sample.x = static_cast<std::int32_t>(x);
    sample.y = static_cast<std::int32_t>(y);
    sample.visible = true;
    out.samples.push_back(sample);
    if (num("button_state", &button) && button != 0) {
      capture::CursorSidecarClick click;
      click.t_ms = sample.t_ms;
      out.clicks.push_back(click);
    }
  }
  std::sort(out.samples.begin(), out.samples.end(),
            [](const capture::CursorSidecarSample& a,
               const capture::CursorSidecarSample& b) {
              return a.t_ms < b.t_ms;
            });
  std::sort(out.clicks.begin(), out.clicks.end(),
            [](const capture::CursorSidecarClick& a,
               const capture::CursorSidecarClick& b) {
              return a.t_ms < b.t_ms;
            });
  return out;
}

// ---------------------------------------------------------------------
// Stage 1D — seek samples + measurement window state
// ---------------------------------------------------------------------

struct SeekSample {
  bool user_driven = false;      // false = programmed by the timer
  std::int64_t target_ms = 0;    // requested playback position
  std::int64_t call_qpc = 0;     // QPC ticks at the moment Position(.) was called
  std::int64_t resolved_qpc = 0; // QPC ticks at the next VideoFrameAvailable
  bool resolved = false;
};

enum class MeasurementState { kNotStarted, kRunning, kDone };

struct DemoState {
  // ---- Direct3D / DXGI / Direct2D ----
  ComPtr<ID3D11Device> d3d_device;
  ComPtr<ID3D11DeviceContext> d3d_context;
  ComPtr<IDXGISwapChain1> swap_chain;
  ComPtr<ID2D1Factory1> d2d_factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> d2d_context;
  ComPtr<ID2D1Bitmap1> backbuffer_bitmap;
  ComPtr<ID2D1SolidColorBrush> black_brush;

  // ---- WinRT MediaPlayer ----
  winrt_dxd3d::IDirect3DDevice winrt_device{nullptr};
  winrt_playback::MediaPlayer player{nullptr};
  winrt::event_token frame_token{};

  // ---- Per-frame video target + composition ----
  // Owns the offscreen video texture (the surface MediaPlayer copies
  // into), the WinRT surface wrapper, the D2D bitmap wrapper, and the
  // radial highlight brush. Drives the BeginDraw / DrawBitmap / halo
  // sequence each frame. Shared with the Stage 2A texture bridge in
  // Stage 2A-2.
  clingfy::preview::PreviewCompositor compositor;

  // ---- Window state ----
  HWND hwnd = nullptr;
  HWND slider_hwnd = nullptr;
  UINT client_width = kDefaultWidth;
  UINT client_height = kDefaultHeight;

  // ---- Synchronization ----
  std::mutex render_mutex;
  std::atomic<bool> shutting_down{false};
  // True while the user is dragging the trackbar thumb. The position
  // poll timer skips updating the slider in this window so the thumb
  // doesn't fight the mouse.
  std::atomic<bool> user_dragging{false};
  std::wstring gpu_description;

  // ---- CLI + cursor fixture ----
  std::wstring video_path;
  std::wstring cursor_path;
  capture::CursorSidecarData cursor;
  bool cursor_mode = false;

  // ---- Zoom state ----
  ZoomState zoom;

  // ---- Measurement / seek tracking ----
  std::atomic<MeasurementState> measurement_state{
      MeasurementState::kNotStarted};
  std::int64_t measurement_start_qpc = 0;
  std::atomic<bool> programmed_seek1_fired{false};
  std::atomic<bool> programmed_seek2_fired{false};
  // SeekSample[] guarded by render_mutex. Programmed and user seeks
  // both push onto it; the next VideoFrameAvailable fills resolved_qpc.
  std::vector<SeekSample> seek_samples;
  bool stage1d_artifact_written = false;

  // ---- Stats (four buckets when cursor_mode is on) ----
  clingfy::preview::FrameTimingCollector timing_total;
  clingfy::preview::FrameTimingCollector timing_copy;
  clingfy::preview::FrameTimingCollector timing_render;
  clingfy::preview::FrameTimingCollector timing_present;
  std::atomic<bool> stats_printed{false};
  std::atomic<std::uint64_t> dropped_frames{0};
};

// ---------------------------------------------------------------------
// CLI parsing (unchanged from 1C)
// ---------------------------------------------------------------------

std::wstring ExtractFlag(int argc, LPWSTR* argv, const std::wstring& flag) {
  std::wstring out;
  if (argv == nullptr) return out;
  const std::wstring with_eq = flag + L"=";
  for (int i = 0; i < argc; ++i) {
    std::wstring a = argv[i];
    if (a.rfind(with_eq, 0) == 0) {
      out = a.substr(with_eq.size());
      break;
    }
    if (a == flag && i + 1 < argc) {
      out = argv[i + 1];
      break;
    }
  }
  if (out.size() >= 2 && out.front() == L'"' && out.back() == L'"') {
    out = out.substr(1, out.size() - 2);
  }
  return out;
}

std::wstring EnvVar(const wchar_t* name) {
  wchar_t buf[MAX_PATH * 2] = {};
  const DWORD n = ::GetEnvironmentVariableW(name, buf, ARRAYSIZE(buf));
  if (n > 0 && n < ARRAYSIZE(buf)) return std::wstring(buf);
  return std::wstring();
}

struct CliPaths {
  std::wstring video;
  std::wstring cursor;
};
CliPaths ParseCliPaths(LPWSTR cmdline) {
  CliPaths out;
  int argc = 0;
  LPWSTR* argv = ::CommandLineToArgvW(cmdline, &argc);
  out.video = ExtractFlag(argc, argv, L"--video");
  out.cursor = ExtractFlag(argc, argv, L"--cursor");
  if (argv != nullptr) ::LocalFree(argv);
  if (out.video.empty()) out.video = EnvVar(L"CLINGFY_POC_VIDEO");
  if (out.cursor.empty()) out.cursor = EnvVar(L"CLINGFY_POC_CURSOR");
  return out;
}

double NowSeconds() {
  LARGE_INTEGER now{}, freq{};
  ::QueryPerformanceCounter(&now);
  ::QueryPerformanceFrequency(&freq);
  return freq.QuadPart > 0
             ? static_cast<double>(now.QuadPart) / freq.QuadPart
             : 0.0;
}

std::int64_t QpcTicks() {
  LARGE_INTEGER v{};
  ::QueryPerformanceCounter(&v);
  return static_cast<std::int64_t>(v.QuadPart);
}

std::int64_t QpcFrequencyTicks() {
  static const std::int64_t freq = []() {
    LARGE_INTEGER v{};
    ::QueryPerformanceFrequency(&v);
    return static_cast<std::int64_t>(v.QuadPart);
  }();
  return freq;
}

double TicksToMs(std::int64_t ticks) {
  const auto freq = QpcFrequencyTicks();
  return freq > 0
             ? (static_cast<double>(ticks) * 1000.0) /
                   static_cast<double>(freq)
             : 0.0;
}

double TicksToSeconds(std::int64_t ticks) {
  const auto freq = QpcFrequencyTicks();
  return freq > 0
             ? static_cast<double>(ticks) / static_cast<double>(freq)
             : 0.0;
}

// ---------------------------------------------------------------------
// Stats / artifact writers
// ---------------------------------------------------------------------

void PrintStatsOnce(DemoState& state) {
  bool expected = false;
  if (!state.stats_printed.compare_exchange_strong(expected, true)) {
    return;
  }
  using clingfy::preview::FrameTimingCollector;
  if (!state.cursor_mode) {
    const auto stats = state.timing_total.ComputeStats();
    std::fprintf(stderr, "STAGE1B_STATS %s  dropped=%llu\n",
                 FrameTimingCollector::FormatStats(stats).c_str(),
                 static_cast<unsigned long long>(
                     state.dropped_frames.load()));
  } else {
    const auto total = state.timing_total.ComputeStats();
    const auto copy = state.timing_copy.ComputeStats();
    const auto render = state.timing_render.ComputeStats();
    const auto present = state.timing_present.ComputeStats();
    std::fprintf(
        stderr,
        "STAGE1C_STATS bucket=total    %s  dropped=%llu\n",
        FrameTimingCollector::FormatStats(total).c_str(),
        static_cast<unsigned long long>(state.dropped_frames.load()));
    std::fprintf(stderr, "STAGE1C_STATS bucket=copy     %s\n",
                 FrameTimingCollector::FormatStats(copy).c_str());
    std::fprintf(stderr, "STAGE1C_STATS bucket=render   %s\n",
                 FrameTimingCollector::FormatStats(render).c_str());
    std::fprintf(stderr, "STAGE1C_STATS bucket=present  %s\n",
                 FrameTimingCollector::FormatStats(present).c_str());
  }
  std::fflush(stderr);
}

std::string UtcTimestampNow() {
  std::time_t now = std::time(nullptr);
  std::tm tm_utc{};
#if defined(_MSC_VER)
  ::gmtime_s(&tm_utc, &now);
#else
  tm_utc = *std::gmtime(&now);
#endif
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ",
                tm_utc.tm_year + 1900, tm_utc.tm_mon + 1, tm_utc.tm_mday,
                tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec);
  return std::string(buf);
}

// Best-effort "Windows 10/11, build N" string for the artifact header.
// RtlGetVersion lives in ntdll and is the only call that doesn't go
// through the compat shim layer.
std::string WindowsVersionString() {
  using RtlGetVersionFn = NTSTATUS(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return "unknown";
  auto fn = reinterpret_cast<RtlGetVersionFn>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (fn == nullptr) return "unknown";
  RTL_OSVERSIONINFOW v{};
  v.dwOSVersionInfoSize = sizeof(v);
  if (fn(&v) != 0) return "unknown";
  char buf[64];
  std::snprintf(buf, sizeof(buf), "Windows %lu.%lu build %lu",
                static_cast<unsigned long>(v.dwMajorVersion),
                static_cast<unsigned long>(v.dwMinorVersion),
                static_cast<unsigned long>(v.dwBuildNumber));
  return std::string(buf);
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(),
                        static_cast<int>(w.size()), out.data(), needed,
                        nullptr, nullptr);
  return out;
}

// Pulled in PrepareDevices() so the artifact writer doesn't have to
// re-walk DXGI.
std::wstring QueryGpuDescription(ID3D11Device* device) {
  if (device == nullptr) return L"unknown";
  ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgi_device)))) {
    return L"unknown";
  }
  ComPtr<IDXGIAdapter> adapter;
  if (FAILED(dxgi_device->GetAdapter(adapter.GetAddressOf()))) {
    return L"unknown";
  }
  DXGI_ADAPTER_DESC desc{};
  if (FAILED(adapter->GetDesc(&desc))) return L"unknown";
  return std::wstring(desc.Description);
}

void WriteStage1dArtifact(DemoState& state, bool measurement_completed,
                          double measurement_duration_seconds) {
  std::ofstream f;
  f.open(kStage1dResultPath,
         std::ios::out | std::ios::trunc | std::ios::binary);
  if (!f.is_open()) {
    std::fprintf(stderr,
                 "STAGE1D_ARTIFACT failed to open %ls for writing\n",
                 kStage1dResultPath);
    return;
  }

  using clingfy::preview::FrameTimingCollector;
  const auto total = state.timing_total.ComputeStats();
  const auto copy = state.timing_copy.ComputeStats();
  const auto render = state.timing_render.ComputeStats();
  const auto present = state.timing_present.ComputeStats();

  // ---- Header ----
  f << "# Stage 1D — 30-second measurement\n\n";
  f << "- **Generated:** " << UtcTimestampNow() << " (UTC)\n";
  f << "- **Status:** "
    << (measurement_completed ? "completed (30 s elapsed)"
                              : "partial — exe closed before window expired")
    << "\n";
  char dur_buf[32];
  std::snprintf(dur_buf, sizeof(dur_buf), "%.2f",
                measurement_duration_seconds);
  f << "- **Measurement window:** " << dur_buf << " s\n";
  f << "- **Mode:** " << (state.cursor_mode ? "cursor (1C+1D)" : "video-only (1B+1D)")
    << "\n\n";

  // ---- System info ----
  f << "## System info\n\n";
  f << "- **OS:** " << WindowsVersionString() << "\n";
  f << "- **GPU:** " << WideToUtf8(state.gpu_description) << "\n";
  f << "- **Video:** " << state.compositor.video_width() << " × "
    << state.compositor.video_height()
    << " px\n";
  f << "- **Video path:** `" << WideToUtf8(state.video_path) << "`\n";
  if (!state.cursor_path.empty()) {
    f << "- **Cursor path:** `" << WideToUtf8(state.cursor_path)
      << "` (" << state.cursor_events.size() << " events)\n";
  }
  f << "\n";

  // ---- Per-bucket stats ----
  auto fmt_bucket = [&](const char* name, const auto& s) {
    char buf[256];
    std::snprintf(
        buf, sizeof(buf),
        "| %-7s | %5zu | %7.3f | %7.3f | %7.3f | %7.3f |\n",
        name, s.frame_count, s.min_ms, s.median_ms, s.p99_ms, s.max_ms);
    f << buf;
  };
  f << "## Per-bucket frame timings (ms)\n\n";
  f << "| bucket  | frames |    min  | median  |   p99   |   max   |\n";
  f << "|---------|-------:|--------:|--------:|--------:|--------:|\n";
  fmt_bucket("total", total);
  if (state.cursor_mode) {
    fmt_bucket("copy", copy);
    fmt_bucket("render", render);
    fmt_bucket("present", present);
  }
  f << "\n";
  f << "Dropped frames during the measurement window: "
    << state.dropped_frames.load() << "\n\n";

  // ---- Seek samples ----
  f << "## Seek samples\n\n";
  if (state.seek_samples.empty()) {
    f << "_No seek samples captured during the measurement window._\n\n";
  } else {
    f << "| source       | target (ms) | resolved | latency (ms) |\n";
    f << "|--------------|------------:|:--------:|-------------:|\n";
    for (const auto& s : state.seek_samples) {
      char row[256];
      const char* src = s.user_driven ? "user" : "programmed";
      if (s.resolved) {
        const double latency_ms =
            TicksToMs(s.resolved_qpc - s.call_qpc);
        std::snprintf(row, sizeof(row),
                      "| %-12s | %11lld | yes      | %12.3f |\n", src,
                      static_cast<long long>(s.target_ms), latency_ms);
      } else {
        std::snprintf(row, sizeof(row),
                      "| %-12s | %11lld | no       |          —   |\n",
                      src, static_cast<long long>(s.target_ms));
      }
      f << row;
    }
    f << "\n";
  }

  // ---- Verdict ----
  f << "## Verdict vs design-doc Stage 1 bar\n\n";
  f << "- **Bar:** total median ≤ " << kPassBarMedianMs
    << " ms AND total p99 ≤ " << kPassBarP99Ms << " ms (1080p)\n";
  char verdict[256];
  const bool pass_median = total.median_ms <= kPassBarMedianMs;
  const bool pass_p99 = total.p99_ms <= kPassBarP99Ms;
  const bool pass = pass_median && pass_p99;
  std::snprintf(verdict, sizeof(verdict),
                "- **Result:** median=%.3f ms (%s), p99=%.3f ms (%s) → "
                "**%s**\n",
                total.median_ms, pass_median ? "PASS" : "FAIL",
                total.p99_ms, pass_p99 ? "PASS" : "FAIL",
                pass ? "PASS" : "FAIL");
  f << verdict << "\n";
  if (!pass) {
    f << "_Failing this bar means Stage 2's Flutter Texture bridge does "
         "not get the headroom the design doc assumed. Triage before "
         "moving on._\n";
  }
}

// ---------------------------------------------------------------------
// D3D11 / D2D setup (unchanged from 1C)
// ---------------------------------------------------------------------

HRESULT CreateDeviceIndependentResources(DemoState& s) {
  D2D1_FACTORY_OPTIONS opts{};
#if defined(_DEBUG)
  opts.debugLevel = D2D1_DEBUG_LEVEL_INFORMATION;
#endif
  return D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED,
                           __uuidof(ID2D1Factory1), &opts,
                           reinterpret_cast<void**>(
                               s.d2d_factory.ReleaseAndGetAddressOf()));
}

HRESULT CreateD3DAndD2DDevices(DemoState& s) {
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#if defined(_DEBUG)
  flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
  };
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, feature_levels,
      ARRAYSIZE(feature_levels), D3D11_SDK_VERSION,
      s.d3d_device.ReleaseAndGetAddressOf(), nullptr,
      s.d3d_context.ReleaseAndGetAddressOf());
#if defined(_DEBUG)
  if (FAILED(hr)) {
    flags &= ~D3D11_CREATE_DEVICE_DEBUG;
    hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, feature_levels,
        ARRAYSIZE(feature_levels), D3D11_SDK_VERSION,
        s.d3d_device.ReleaseAndGetAddressOf(), nullptr,
        s.d3d_context.ReleaseAndGetAddressOf());
  }
#endif
  if (FAILED(hr)) return hr;

  ComPtr<ID3D11Multithread> mt;
  if (SUCCEEDED(s.d3d_context.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }

  ComPtr<IDXGIDevice> dxgi_device;
  hr = s.d3d_device.As(&dxgi_device);
  if (FAILED(hr)) return hr;
  hr = s.d2d_factory->CreateDevice(
      dxgi_device.Get(), s.d2d_device.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;
  hr = s.d2d_device->CreateDeviceContext(
      D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
      s.d2d_context.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  ComPtr<::IInspectable> inspectable;
  hr = ::CreateDirect3D11DeviceFromDXGIDevice(
      dxgi_device.Get(),
      reinterpret_cast<::IInspectable**>(inspectable.GetAddressOf()));
  if (FAILED(hr)) return hr;
  winrt::com_ptr<::IInspectable> winrt_inspectable;
  winrt_inspectable.attach(inspectable.Detach());
  s.winrt_device = winrt_inspectable.as<winrt_dxd3d::IDirect3DDevice>();

  s.gpu_description = QueryGpuDescription(s.d3d_device.Get());
  return S_OK;
}

HRESULT CreateSwapChainForHwnd(DemoState& s, HWND hwnd) {
  ComPtr<IDXGIDevice> dxgi_device;
  HRESULT hr = s.d3d_device.As(&dxgi_device);
  if (FAILED(hr)) return hr;
  ComPtr<IDXGIAdapter> dxgi_adapter;
  hr = dxgi_device->GetAdapter(dxgi_adapter.GetAddressOf());
  if (FAILED(hr)) return hr;
  ComPtr<IDXGIFactory2> factory;
  hr = dxgi_adapter->GetParent(
      __uuidof(IDXGIFactory2),
      reinterpret_cast<void**>(factory.GetAddressOf()));
  if (FAILED(hr)) return hr;

  DXGI_SWAP_CHAIN_DESC1 desc{};
  desc.Width = s.client_width;
  desc.Height = s.client_height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_NONE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  return factory->CreateSwapChainForHwnd(
      s.d3d_device.Get(), hwnd, &desc, nullptr, nullptr,
      s.swap_chain.ReleaseAndGetAddressOf());
}

// EnsureHighlightBrush moved to PreviewCompositor in preview_compositor.cpp.

HRESULT BindBackBuffer(DemoState& s) {
  s.backbuffer_bitmap.Reset();
  s.d2d_context->SetTarget(nullptr);

  ComPtr<IDXGISurface> dxgi_back;
  HRESULT hr = s.swap_chain->GetBuffer(
      0, __uuidof(IDXGISurface),
      reinterpret_cast<void**>(dxgi_back.GetAddressOf()));
  if (FAILED(hr)) return hr;
  const auto props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_IGNORE));
  hr = s.d2d_context->CreateBitmapFromDxgiSurface(
      dxgi_back.Get(), &props,
      s.backbuffer_bitmap.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;
  s.d2d_context->SetTarget(s.backbuffer_bitmap.Get());

  return s.d2d_context->CreateSolidColorBrush(
      D2D1::ColorF(D2D1::ColorF::Black),
      s.black_brush.ReleaseAndGetAddressOf());
}

HRESULT ResizeSwapChain(DemoState& s, UINT w, UINT h) {
  std::lock_guard<std::mutex> lock(s.render_mutex);
  s.client_width = w;
  s.client_height = h;
  s.backbuffer_bitmap.Reset();
  s.d2d_context->SetTarget(nullptr);
  HRESULT hr =
      s.swap_chain->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr)) return hr;
  return BindBackBuffer(s);
}

// EnsureVideoTarget + LetterboxRect / VideoToBackBuffer / ZoomedDestRect
// all moved to preview_compositor.{h,cpp}. The HWND demo reaches them
// via the clingfy::preview namespace (LetterboxRect is also used in
// HandleVideoFrameAvailable for the slider-stripped dest rect below).

// ---------------------------------------------------------------------
// Slider strip — HWND-only geometry. Stays here because the texture
// bridge doesn't have an HWND swap chain underneath.
// ---------------------------------------------------------------------

UINT VideoStripHeight(UINT client_h) {
  return client_h > static_cast<UINT>(kSliderStripPx)
             ? client_h - static_cast<UINT>(kSliderStripPx)
             : client_h;
}

// ---------------------------------------------------------------------
// MediaPlayer helpers + seek tracking
// ---------------------------------------------------------------------

std::int64_t CurrentPlaybackUs(winrt_playback::MediaPlayer const& player) {
  try {
    const auto pos = player.PlaybackSession().Position();
    return std::chrono::duration_cast<std::chrono::microseconds>(pos)
        .count();
  } catch (winrt::hresult_error const&) {
    return -1;
  }
}

std::int64_t NaturalDurationUs(winrt_playback::MediaPlayer const& player) {
  try {
    const auto d = player.PlaybackSession().NaturalDuration();
    return std::chrono::duration_cast<std::chrono::microseconds>(d).count();
  } catch (winrt::hresult_error const&) {
    return 0;
  }
}

void IssueSeek(DemoState& state, std::int64_t target_us, bool user_driven) {
  if (!state.player) return;
  try {
    state.player.PlaybackSession().Position(
        std::chrono::duration_cast<winrt_foundation::TimeSpan>(
            std::chrono::microseconds(target_us)));
  } catch (winrt::hresult_error const&) {
    return;
  }
  SeekSample s;
  s.user_driven = user_driven;
  s.target_ms = target_us / 1000;
  s.call_qpc = QpcTicks();
  {
    std::lock_guard<std::mutex> lock(state.render_mutex);
    state.seek_samples.push_back(s);
  }
  // A seek invalidates the smoother's positional carry-over; reset
  // the "last click" timestamp so a previous hold doesn't bleed into
  // the new playback ts range.
  state.zoom.last_click_ts_us =
      std::numeric_limits<std::int64_t>::min();
}

void MaybeFireProgrammedSeeks(DemoState& state, double elapsed_seconds) {
  if (state.measurement_state.load() != MeasurementState::kRunning) {
    return;
  }
  const std::int64_t duration_us = NaturalDurationUs(state.player);
  if (duration_us <= 0) return;

  // Seek 1: jump to ~80 % of duration. Seek 2: jump back to ~20 %.
  bool expected = false;
  if (elapsed_seconds >= kProgrammedSeek1Seconds &&
      state.programmed_seek1_fired.compare_exchange_strong(expected,
                                                           true)) {
    const std::int64_t target =
        static_cast<std::int64_t>(duration_us * 0.80);
    IssueSeek(state, target, /*user_driven=*/false);
  }
  expected = false;
  if (elapsed_seconds >= kProgrammedSeek2Seconds &&
      state.programmed_seek2_fired.compare_exchange_strong(expected,
                                                           true)) {
    const std::int64_t target =
        static_cast<std::int64_t>(duration_us * 0.20);
    IssueSeek(state, target, /*user_driven=*/false);
  }
}

// Pair the first VideoFrameAvailable callback after a seek with the
// corresponding SeekSample. Multiple seeks back-to-back: only the
// first unresolved entry gets resolved per frame; the next frame
// resolves the next one. With realistic seek cadence (tens of seconds
// apart in the programmed case, ~1 per UI-frame at worst when the
// user drags), the queue is never long.
void ResolvePendingSeeks(DemoState& state, std::int64_t now_qpc) {
  for (auto& s : state.seek_samples) {
    if (!s.resolved) {
      s.resolved = true;
      s.resolved_qpc = now_qpc;
      return;
    }
  }
}

// ---------------------------------------------------------------------
// Per-frame composition (Stage 1B / 1C path + measurement gating)
// ---------------------------------------------------------------------

void HandleVideoFrameAvailable(DemoState& s,
                               winrt_playback::MediaPlayer const& sender) {
  if (s.shutting_down.load()) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  // ---- Stage 1D measurement state transitions ----
  const std::int64_t now_qpc = QpcTicks();
  auto state_now = s.measurement_state.load();
  if (state_now == MeasurementState::kNotStarted) {
    s.measurement_start_qpc = now_qpc;
    s.measurement_state.store(MeasurementState::kRunning);
    state_now = MeasurementState::kRunning;
  }
  const double elapsed =
      TicksToSeconds(now_qpc - s.measurement_start_qpc);
  const bool in_measurement_window =
      state_now == MeasurementState::kRunning &&
      elapsed < kMeasurementWindowSeconds;
  bool should_write_artifact = false;
  if (state_now == MeasurementState::kRunning &&
      elapsed >= kMeasurementWindowSeconds) {
    s.measurement_state.store(MeasurementState::kDone);
    if (!s.stage1d_artifact_written) {
      s.stage1d_artifact_written = true;
      should_write_artifact = true;  // perform the write below, outside the render lock
    }
  }

  // Programmed seeks are fired AFTER the render pass (see end of this
  // function). Doing them up-front used to resolve the just-issued
  // seek against the SAME frame's now_qpc and reported negative
  // latency. Moving the firing to the tail end means any new seek
  // gets resolved by the NEXT VideoFrameAvailable callback, which is
  // the documented frame-server semantics we want to measure.

  // Bracket the total bucket only inside the measurement window so
  // post-window frames don't dilute the stats.
  if (in_measurement_window) s.timing_total.BeginFrame();

  {  // ---- nested scope so the lock_guard releases before
     //      MaybeFireProgrammedSeeks runs (IssueSeek takes the lock)
  std::lock_guard<std::mutex> lock(s.render_mutex);
  ResolvePendingSeeks(s, now_qpc);

  if (!s.swap_chain || !s.backbuffer_bitmap) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    if (in_measurement_window) s.timing_total.EndFrame();
    return;
  }

  const auto session = sender.PlaybackSession();
  const UINT vw = session.NaturalVideoWidth();
  const UINT vh = session.NaturalVideoHeight();
  if (vw == 0 || vh == 0) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    if (in_measurement_window) s.timing_total.EndFrame();
    return;
  }
  if (FAILED(s.compositor.EnsureResources(s.d3d_device.Get(),
                                          s.d2d_context.Get(), vw, vh))) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    if (in_measurement_window) s.timing_total.EndFrame();
    return;
  }

  // ---- Copy bucket ----
  if (s.cursor_mode && in_measurement_window) s.timing_copy.BeginFrame();
  try {
    sender.CopyFrameToVideoSurface(s.compositor.winrt_video_surface());
  } catch (winrt::hresult_error const&) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    if (s.cursor_mode && in_measurement_window) s.timing_copy.EndFrame();
    if (in_measurement_window) s.timing_total.EndFrame();
    return;
  }
  if (s.cursor_mode && in_measurement_window) s.timing_copy.EndFrame();

  // ---- Render bucket ----
  // The slider strip is painted by Windows (its own child HWND);
  // VideoStripHeight subtracts it so the video dest never overlaps.
  const UINT video_strip_h = VideoStripHeight(s.client_height);
  const D2D1_RECT_F dest = clingfy::preview::LetterboxRect(
      s.client_width, video_strip_h, s.compositor.video_width(),
      s.compositor.video_height());
  const std::int64_t playback_us =
      s.cursor_mode ? CurrentPlaybackUs(sender) : -1;

  if (s.cursor_mode && in_measurement_window) s.timing_render.BeginFrame();
  s.d2d_context->BeginDraw();
  // PreviewCompositor::ComposeFrame does Clear + DrawBitmap +
  // optional zoom + highlight in one go. cursor_events empty means
  // video-only mode; zoom and halo are skipped and the call is a
  // pure DrawBitmap.
  // Compositor handles an empty sidecar as the "video-only" path
  // internally; no separate codepath needed when cursor_mode is off
  // (s.cursor has no samples in that case).
  s.compositor.ComposeFrame(s.d2d_context.Get(), dest, s.cursor,
                            playback_us, NowSeconds(), s.zoom);
  const HRESULT end_hr = s.d2d_context->EndDraw();
  if (end_hr == D2DERR_RECREATE_TARGET) {
    BindBackBuffer(s);
  }
  if (s.cursor_mode && in_measurement_window) s.timing_render.EndFrame();

  // ---- Present bucket ----
  if (s.cursor_mode && in_measurement_window) s.timing_present.BeginFrame();
  s.swap_chain->Present(0, 0);
  if (s.cursor_mode && in_measurement_window) s.timing_present.EndFrame();

  if (in_measurement_window) s.timing_total.EndFrame();
  }  // ---- lock_guard releases here (close of nested scope) ----

  // Outside the lock — IssueSeek acquires render_mutex internally, so
  // doing it inside the lock above would deadlock. Doing it here also
  // gives seeks fired THIS frame the proper "resolved by the NEXT
  // VideoFrameAvailable" semantics, instead of the broken "resolved
  // by the same frame's now_qpc" path that produced negative latencies.
  MaybeFireProgrammedSeeks(s, elapsed);

  // FrameTimingCollector::ComputeStats() copies + sorts; safe outside
  // the lock since no other thread mutates the samples vectors. Same
  // for the seek_samples snapshot below.
  if (should_write_artifact) {
    WriteStage1dArtifact(s, /*completed=*/true, kMeasurementWindowSeconds);
    std::fprintf(stderr,
                 "STAGE1D_ARTIFACT wrote %ls (completed run)\n",
                 kStage1dResultPath);
    std::fflush(stderr);
  }
}

// ---------------------------------------------------------------------
// Win32 plumbing — adds Stage 1D slider + position-poll timer
// ---------------------------------------------------------------------

// Map the trackbar's integer position (0..kSliderRange) to a playback
// position in microseconds, given the current natural duration.
std::int64_t SliderPosToUs(int slider_pos, std::int64_t duration_us) {
  if (slider_pos < 0) slider_pos = 0;
  if (slider_pos > kSliderRange) slider_pos = kSliderRange;
  if (duration_us <= 0) return 0;
  return static_cast<std::int64_t>(
      (static_cast<double>(slider_pos) /
       static_cast<double>(kSliderRange)) *
      static_cast<double>(duration_us));
}

int UsToSliderPos(std::int64_t us, std::int64_t duration_us) {
  if (duration_us <= 0) return 0;
  double r = static_cast<double>(us) / static_cast<double>(duration_us);
  if (r < 0.0) r = 0.0;
  if (r > 1.0) r = 1.0;
  return static_cast<int>(r * kSliderRange + 0.5);
}

void HandleHScroll(DemoState& state, WPARAM wparam) {
  if (!state.slider_hwnd || !state.player) return;
  const int code = LOWORD(wparam);
  switch (code) {
    case TB_THUMBTRACK:
      state.user_dragging.store(true);
      return;  // wait for THUMBPOSITION / ENDTRACK to commit
    case TB_ENDTRACK:
      state.user_dragging.store(false);
      break;
    case TB_THUMBPOSITION:
      state.user_dragging.store(false);
      break;
    case TB_LINEUP:
    case TB_LINEDOWN:
    case TB_PAGEUP:
    case TB_PAGEDOWN:
    case TB_TOP:
    case TB_BOTTOM:
      break;
    default:
      return;
  }
  const LRESULT pos = ::SendMessageW(state.slider_hwnd, TBM_GETPOS, 0, 0);
  const std::int64_t duration_us = NaturalDurationUs(state.player);
  const std::int64_t target_us =
      SliderPosToUs(static_cast<int>(pos), duration_us);
  IssueSeek(state, target_us, /*user_driven=*/true);
}

void HandlePositionPollTick(DemoState& state) {
  if (!state.slider_hwnd || !state.player) return;
  if (state.user_dragging.load()) return;  // don't fight the mouse
  const std::int64_t pos_us = CurrentPlaybackUs(state.player);
  const std::int64_t duration_us = NaturalDurationUs(state.player);
  if (pos_us < 0 || duration_us <= 0) return;
  const int slider_pos = UsToSliderPos(pos_us, duration_us);
  ::SendMessageW(state.slider_hwnd, TBM_SETPOS, TRUE, slider_pos);
}

void LayoutSlider(DemoState& state) {
  if (!state.slider_hwnd) return;
  const int margin = 8;
  const int y = static_cast<int>(state.client_height) - kSliderStripPx + 4;
  ::SetWindowPos(state.slider_hwnd, nullptr, margin, y,
                 static_cast<int>(state.client_width) - margin * 2,
                 kSliderStripPx - 8,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                            LPARAM lparam) {
  auto* state = reinterpret_cast<DemoState*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_CREATE: {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
      auto* st = reinterpret_cast<DemoState*>(cs->lpCreateParams);
      if (st != nullptr) {
        st->slider_hwnd = ::CreateWindowExW(
            0, TRACKBAR_CLASS, L"",
            WS_CHILD | WS_VISIBLE | TBS_HORZ | TBS_NOTICKS, 0, 0, 10, 10,
            hwnd, nullptr, cs->hInstance, nullptr);
        if (st->slider_hwnd) {
          ::SendMessageW(st->slider_hwnd, TBM_SETRANGE, TRUE,
                         MAKELPARAM(0, kSliderRange));
          ::SendMessageW(st->slider_hwnd, TBM_SETPOS, TRUE, 0);
        }
        ::SetTimer(hwnd, kPositionPollTimerId, kPositionPollPeriodMs,
                   nullptr);
      }
      return 0;
    }
    case WM_SIZE: {
      if (state && state->swap_chain) {
        const UINT w = LOWORD(lparam);
        const UINT h = HIWORD(lparam);
        if (w > 0 && h > 0) {
          ResizeSwapChain(*state, w, h);
        }
        LayoutSlider(*state);
      }
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      ::BeginPaint(hwnd, &ps);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_HSCROLL: {
      if (state) HandleHScroll(*state, wparam);
      return 0;
    }
    case WM_TIMER: {
      if (state && wparam == kPositionPollTimerId) {
        HandlePositionPollTick(*state);
      }
      return 0;
    }
    case WM_CLOSE: {
      if (state) PrintStatsOnce(*state);
      ::DestroyWindow(hwnd);
      return 0;
    }
    case WM_DESTROY: {
      if (state) PrintStatsOnce(*state);
      ::KillTimer(hwnd, kPositionPollTimerId);
      ::PostQuitMessage(0);
      return 0;
    }
    case WM_KEYDOWN: {
      if (wparam == VK_ESCAPE) {
        ::SendMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;
    }
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

int ShowErrorAndExit(const std::wstring& msg, int code) {
  ::MessageBoxW(nullptr, msg.c_str(), kWindowTitle, MB_ICONERROR);
  return code;
}

int RunDemo(HINSTANCE hinstance, int show_cmd, LPWSTR cmdline) {
  // ---- 1. Parse CLI ----
  const auto paths = ParseCliPaths(cmdline);
  if (paths.video.empty()) {
    return ShowErrorAndExit(
        L"No video specified. Pass --video=PATH or set the\n"
        L"CLINGFY_POC_VIDEO environment variable.",
        100);
  }
  if (::GetFileAttributesW(paths.video.c_str()) ==
      INVALID_FILE_ATTRIBUTES) {
    return ShowErrorAndExit(
        L"Video file not found:\n" + paths.video, 101);
  }
  if (!paths.cursor.empty() &&
      ::GetFileAttributesW(paths.cursor.c_str()) ==
          INVALID_FILE_ATTRIBUTES) {
    return ShowErrorAndExit(
        L"Cursor file not found:\n" + paths.cursor, 102);
  }

  // ---- 2. WinRT apartment + common controls ----
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_BAR_CLASSES};
  ::InitCommonControlsEx(&icc);

  // ---- 3. Window class ----
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = hinstance;
  wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr;
  wc.lpszClassName = kWindowClassName;
  if (!::RegisterClassExW(&wc)) return 1;

  DemoState state;
  state.video_path = paths.video;
  state.cursor_path = paths.cursor;
  if (!paths.cursor.empty()) {
    state.cursor = LoadPocCursorJsonl(paths.cursor);
    state.cursor_mode = !state.cursor.samples.empty();
    if (!state.cursor_mode) {
      return ShowErrorAndExit(
          L"Cursor file parsed to zero events:\n" + paths.cursor +
              L"\nCheck JSONL syntax (ts_us, x, y required).",
          103);
    }
  }

  // ---- 4. Devices ----
  if (FAILED(CreateDeviceIndependentResources(state))) {
    return ShowErrorAndExit(L"Failed to create D2D factory.", 2);
  }
  if (FAILED(CreateD3DAndD2DDevices(state))) {
    return ShowErrorAndExit(L"Failed to create D3D11 / D2D device.", 3);
  }

  // ---- 5. Window ----
  RECT window_rect = {0, 0, kDefaultWidth, kDefaultHeight};
  ::AdjustWindowRectEx(&window_rect, WS_OVERLAPPEDWINDOW, FALSE,
                       WS_EX_APPWINDOW);
  state.hwnd = ::CreateWindowExW(
      WS_EX_APPWINDOW, kWindowClassName, kWindowTitle, WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, window_rect.right - window_rect.left,
      window_rect.bottom - window_rect.top, nullptr, nullptr, hinstance,
      &state);
  if (!state.hwnd) return 4;
  if (FAILED(CreateSwapChainForHwnd(state, state.hwnd))) {
    ::DestroyWindow(state.hwnd);
    return ShowErrorAndExit(L"Failed to create DXGI swap chain.", 5);
  }
  if (FAILED(BindBackBuffer(state))) {
    ::DestroyWindow(state.hwnd);
    return 6;
  }
  // Initial slider layout — uses the default client size until the
  // first WM_SIZE refines it.
  LayoutSlider(state);
  ::ShowWindow(state.hwnd, show_cmd);
  ::UpdateWindow(state.hwnd);

  // ---- 6. MediaPlayer + frame-server mode ----
  try {
    state.player = winrt_playback::MediaPlayer();
    state.player.IsVideoFrameServerEnabled(true);
    state.player.IsLoopingEnabled(true);

    wchar_t full[MAX_PATH * 2] = {};
    const DWORD n =
        ::GetFullPathNameW(state.video_path.c_str(), ARRAYSIZE(full),
                           full, nullptr);
    if (n == 0 || n >= ARRAYSIZE(full)) {
      ::DestroyWindow(state.hwnd);
      return ShowErrorAndExit(
          L"Could not resolve video path to an absolute file URI.", 7);
    }
    std::wstring uri = L"file:///";
    for (DWORD i = 0; i < n; ++i) {
      uri.push_back(full[i] == L'\\' ? L'/' : full[i]);
    }
    const winrt_foundation::Uri winrt_uri{uri};
    state.player.Source(winrt_media::MediaSource::CreateFromUri(winrt_uri));

    state.frame_token = state.player.VideoFrameAvailable(
        [&state](winrt_playback::MediaPlayer const& sender,
                 winrt_foundation::IInspectable const& /*args*/) {
          // HandleVideoFrameAvailable owns the Running→Done
          // transition AND the artifact write that goes with it.
          // The lambda just dispatches.
          HandleVideoFrameAvailable(state, sender);
        });
    state.player.Play();
  } catch (winrt::hresult_error const& e) {
    ::DestroyWindow(state.hwnd);
    return ShowErrorAndExit(
        std::wstring(L"MediaPlayer setup failed: ") + e.message().c_str(),
        8);
  }

  // ---- 7. Message loop ----
  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  // ---- 8. Tear down ----
  state.shutting_down.store(true);
  try {
    if (state.player) {
      state.player.Pause();
      if (state.frame_token.value) {
        state.player.VideoFrameAvailable(state.frame_token);
      }
      state.player.Close();
      state.player = nullptr;
    }
  } catch (winrt::hresult_error const&) {
    // Best-effort.
  }
  // If the measurement didn't complete (early close), still write a
  // partial artifact so the run is captured.
  if (!state.stage1d_artifact_written) {
    state.stage1d_artifact_written = true;
    const double partial_elapsed =
        state.measurement_state.load() == MeasurementState::kNotStarted
            ? 0.0
            : TicksToSeconds(QpcTicks() - state.measurement_start_qpc);
    WriteStage1dArtifact(state, /*completed=*/false, partial_elapsed);
    std::fprintf(stderr,
                 "STAGE1D_ARTIFACT wrote %ls (partial run, %.2f s)\n",
                 kStage1dResultPath, partial_elapsed);
    std::fflush(stderr);
  }
  PrintStatsOnce(state);
  return static_cast<int>(msg.wParam);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE hinstance,
                      _In_opt_ HINSTANCE /*hprev*/,
                      _In_ LPWSTR cmdline, _In_ int show_cmd) {
  return RunDemo(hinstance, show_cmd, cmdline);
}
