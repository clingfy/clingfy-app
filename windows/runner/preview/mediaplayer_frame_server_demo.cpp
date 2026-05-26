// Windows Phase 5 POC — Stage 1B (video-only) + Stage 1C (video + cursor).
//
// What this is: the second opt-in standalone Win32 GUI executable in the
// preview/ POC set, peer to live_compositor_demo.exe from Stage 1A0.
// One binary covers both Stage 1B and Stage 1C measurement runs:
//
//   * Pass --video=PATH only (or just `CLINGFY_POC_VIDEO`):
//     Stage 1B behavior — load the MP4 via MediaPlayer frame-server,
//     CopyFrameToVideoSurface onto an offscreen D3D11 texture, D2D
//     blit (letterboxed) onto the swap-chain back buffer, Present.
//     STAGE1B_STATS goes to stderr on close.
//
//   * Pass --cursor=PATH too (or `CLINGFY_POC_CURSOR`):
//     Stage 1C behavior — same pipeline, plus per-frame cursor /
//     click composition. cursor.jsonl is hand-authored, one JSON
//     object per line, with fields:
//         ts_us         video-timeline timestamp (microseconds)
//         x, y          cursor position in VIDEO PIXEL coordinates
//         button_state  0 = up sample, non-zero = mouse-down
//         monitor_id    integer, currently unused
//     The compositor looks up the nearest cursor sample for the
//     current playback timestamp and the nearest CLICK event within
//     ±500 ms of it. A click triggers a zoom-in to
//     `kZoomFactorDefault` centered on the click position. After the
//     `kZoomMinOnSeconds` hold expires it decays back to 1.0×. A
//     radial highlight is drawn at the cursor position with alpha
//     tied to the zoom intensity. STAGE1C_STATS goes to stderr on
//     close, with separate per-bucket lines (total / copy / render /
//     present).
//
// What this is NOT: production code. It is not linked into the main
// Flutter app. It does not touch the bridge contract or any
// production preview surface. The cmake option
// BUILD_LIVE_COMPOSITOR_POC defaults to OFF, so `flutter build
// windows` ignores this file entirely.
//
// Stage 1C deliberately stays inside the same constraints as 1A0/1B:
//   - No seek slider.
//   - No Flutter Texture bridge.
//   - No real cursor sidecar capture (hand-authored JSONL only).
//   - No production preview/player bridge methods touched.
//   - No Dart bridge contract touched.
//   - All zoom timing / intensity constants come from
//     `preview/zoom_easing_constants.h`, the source-of-truth header
//     populated in Step 0 (#96). Never hard-code a zoom magnitude
//     or smoother strength here.
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
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "preview/frame_timing.h"
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

// ±500 ms click-lookup window. Per the Stage 1C instructions; not a
// constant from zoom_easing_constants.h because it describes the POC's
// hand-authored cursor.jsonl semantics, not the macOS smoother math.
constexpr std::int64_t kClickLookupWindowUs = 500'000;

// Cursor highlight radius in BACK BUFFER PIXELS. The Stage 1C scope
// adds a radial halo at the cursor position; the macOS engine does not
// have a parity constant for this (we explicitly excluded it from
// zoom_easing_constants.h to avoid inventing one). 60 px reads well at
// 1280×720 and 1920×1080 default windows; future production work can
// scale it with viewport DPI.
constexpr float kHighlightRadiusPx = 60.0f;

// ---------------------------------------------------------------------
// Cursor event model + hand-authored JSONL loader
// ---------------------------------------------------------------------

struct CursorEvent {
  std::int64_t ts_us = 0;     // video-timeline timestamp, microseconds
  double x = 0.0;             // video pixel x
  double y = 0.0;             // video pixel y
  int button_state = 0;       // 0 = up sample, non-zero = mouse-down
  int monitor_id = 0;         // currently unused; preserved for symmetry
};

// Skip whitespace at the start of [pos, s.size()). Returns the new
// index. JSON allows space, tab, newline, carriage return between
// tokens; this matches that set.
std::size_t SkipWs(const std::string& s, std::size_t pos) {
  while (pos < s.size() &&
         (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' ||
          s[pos] == '\r')) {
    ++pos;
  }
  return pos;
}

// Find the value of a numeric field named `key` in `line`. Returns
// true on success. Tolerates:
//   * arbitrary whitespace
//   * either "key": value or unquoted key: value (a few JSONL files
//     in the wild are loose about quoting)
//   * scientific notation, signs, decimals
template <typename T>
bool ReadJsonNumber(const std::string& line, const std::string& key,
                    T& out) {
  // We accept the field whether it appears as `"key"` or `key`. The
  // search target is the key name surrounded by an optional quote
  // and followed (after whitespace) by ':'.
  std::string quoted = std::string("\"") + key + "\"";
  std::size_t pos = line.find(quoted);
  if (pos == std::string::npos) {
    pos = line.find(key);
    if (pos == std::string::npos) return false;
    // Make sure we matched a whole word, not a substring of another.
    if (pos > 0 && (std::isalnum(static_cast<unsigned char>(line[pos - 1])) ||
                    line[pos - 1] == '_')) {
      return false;
    }
    const std::size_t after = pos + key.size();
    if (after < line.size() && (std::isalnum(static_cast<unsigned char>(
                                    line[after])) ||
                                line[after] == '_')) {
      return false;
    }
    pos = after;
  } else {
    pos += quoted.size();
  }
  pos = SkipWs(line, pos);
  if (pos >= line.size() || line[pos] != ':') return false;
  pos = SkipWs(line, pos + 1);

  // Parse a number with the standard library; std::stod / std::stoll
  // handle signs, decimals, and scientific notation.
  const char* start = line.c_str() + pos;
  char* end = nullptr;
  if constexpr (std::is_integral_v<T>) {
    const long long v = std::strtoll(start, &end, 10);
    if (end == start) return false;
    out = static_cast<T>(v);
  } else {
    const double v = std::strtod(start, &end);
    if (end == start) return false;
    out = static_cast<T>(v);
  }
  return true;
}

// Parse one JSONL line into a CursorEvent. Returns false if the line
// does not look like a cursor record (blank, comment, missing
// required fields). Required fields: ts_us, x, y. Optional:
// button_state (defaults to 0), monitor_id (defaults to 0).
bool ParseCursorLine(const std::string& line, CursorEvent& out) {
  const auto first = line.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return false;
  if (line[first] != '{') return false;

  CursorEvent ev;
  if (!ReadJsonNumber<std::int64_t>(line, "ts_us", ev.ts_us)) return false;
  if (!ReadJsonNumber<double>(line, "x", ev.x)) return false;
  if (!ReadJsonNumber<double>(line, "y", ev.y)) return false;
  ReadJsonNumber<int>(line, "button_state", ev.button_state);
  ReadJsonNumber<int>(line, "monitor_id", ev.monitor_id);
  out = ev;
  return true;
}

// Load and sort cursor events from a UTF-8 JSONL file. Bad lines are
// silently skipped (this is a hand-authored fixture — strict validation
// would just slow iteration down). On any IO failure returns empty.
std::vector<CursorEvent> LoadCursorJsonl(const std::wstring& path) {
  std::vector<CursorEvent> out;
  std::ifstream in(path);
  if (!in.is_open()) return out;
  std::string line;
  while (std::getline(in, line)) {
    CursorEvent ev;
    if (ParseCursorLine(line, ev)) {
      out.push_back(ev);
    }
  }
  std::sort(out.begin(), out.end(),
            [](const CursorEvent& a, const CursorEvent& b) {
              return a.ts_us < b.ts_us;
            });
  return out;
}

// Nearest cursor sample by absolute distance in ts. Linear search;
// hand-authored fixtures are tiny so this is fast enough. Returns
// nullptr only when `events` is empty.
const CursorEvent* FindNearestCursor(
    const std::vector<CursorEvent>& events, std::int64_t ts_us) {
  if (events.empty()) return nullptr;
  // Binary search for the upper bound, then compare with the lower
  // neighbour to pick the closer one.
  auto it = std::lower_bound(
      events.begin(), events.end(), ts_us,
      [](const CursorEvent& e, std::int64_t v) { return e.ts_us < v; });
  if (it == events.end()) return &events.back();
  if (it == events.begin()) return &*it;
  auto prev = std::prev(it);
  const std::int64_t diff_prev = std::llabs(prev->ts_us - ts_us);
  const std::int64_t diff_next = std::llabs(it->ts_us - ts_us);
  return diff_prev <= diff_next ? &*prev : &*it;
}

// Nearest event whose button_state != 0 within ±window_us of ts_us.
// Returns nullptr when no click qualifies.
const CursorEvent* FindNearestClick(
    const std::vector<CursorEvent>& events, std::int64_t ts_us,
    std::int64_t window_us) {
  if (events.empty()) return nullptr;
  // Walk neighbours of the lower-bound until distance exceeds the
  // window. Hand-authored fixtures rarely exceed a few dozen entries
  // so this is fine.
  const CursorEvent* best = nullptr;
  std::int64_t best_diff = window_us + 1;
  for (const auto& e : events) {
    if (e.button_state == 0) continue;
    const std::int64_t diff = std::llabs(e.ts_us - ts_us);
    if (diff <= window_us && diff < best_diff) {
      best = &e;
      best_diff = diff;
    }
  }
  return best;
}

// ---------------------------------------------------------------------
// Zoom state + smoother (per-frame lerp toward target)
// ---------------------------------------------------------------------

struct ZoomState {
  double current_zoom = 1.0;
  double current_x = 0.0;  // in VIDEO PIXEL coordinates
  double current_y = 0.0;
  double target_zoom = 1.0;
  double target_x = 0.0;
  double target_y = 0.0;
  double last_update_seconds = -1.0;
  // Most recent click ts (microseconds), used to enforce the
  // kZoomMinOnSeconds hold after a click before decay can start.
  std::int64_t last_click_ts_us = std::numeric_limits<std::int64_t>::min();
};

// One per-frame smoother step. Updates current_* toward target_* with
// the exponential smoothing alpha from
// preview/zoom_easing_constants.h. `now_seconds` is wall-clock from
// QueryPerformanceCounter on the worker thread.
void StepZoomSmoother(ZoomState& z, double now_seconds) {
  using namespace clingfy::preview;
  if (z.last_update_seconds < 0.0) {
    z.last_update_seconds = now_seconds;
    return;
  }
  double dt = now_seconds - z.last_update_seconds;
  z.last_update_seconds = now_seconds;
  if (dt < kZoomFollowMinDtSeconds) dt = kZoomFollowMinDtSeconds;
  if (dt > kZoomFollowMaxDtSeconds) dt = kZoomFollowMaxDtSeconds;

  const double normalized_frames = dt * kZoomFollowReferenceFPS;
  const double strength = kZoomFollowStrengthDefault;
  const double alpha =
      1.0 - std::pow(1.0 - strength, normalized_frames);

  z.current_zoom += (z.target_zoom - z.current_zoom) * alpha;
  z.current_x += (z.target_x - z.current_x) * alpha;
  z.current_y += (z.target_y - z.current_y) * alpha;
}

// ---------------------------------------------------------------------
// Demo state
// ---------------------------------------------------------------------

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
  ComPtr<ID2D1RadialGradientBrush> highlight_brush;

  // ---- WinRT MediaPlayer ----
  winrt_dxd3d::IDirect3DDevice winrt_device{nullptr};
  winrt_playback::MediaPlayer player{nullptr};
  winrt::event_token frame_token{};

  // ---- Per-frame video surface ----
  ComPtr<ID3D11Texture2D> video_texture;
  ComPtr<ID2D1Bitmap1> video_bitmap;
  winrt_dxd3d::IDirect3DSurface winrt_video_surface{nullptr};
  UINT video_width = 0;
  UINT video_height = 0;

  // ---- Window state ----
  HWND hwnd = nullptr;
  UINT client_width = kDefaultWidth;
  UINT client_height = kDefaultHeight;

  // ---- Synchronization ----
  std::mutex render_mutex;
  std::atomic<bool> shutting_down{false};

  // ---- CLI + cursor fixture ----
  std::wstring video_path;
  std::wstring cursor_path;
  std::vector<CursorEvent> cursor_events;
  bool cursor_mode = false;  // true → STAGE1C_STATS, false → STAGE1B_STATS

  // ---- Zoom state ----
  ZoomState zoom;

  // ---- Stats (four buckets when cursor_mode is on) ----
  clingfy::preview::FrameTimingCollector timing_total;
  clingfy::preview::FrameTimingCollector timing_copy;
  clingfy::preview::FrameTimingCollector timing_render;
  clingfy::preview::FrameTimingCollector timing_present;
  std::atomic<bool> stats_printed{false};
  std::atomic<std::uint64_t> dropped_frames{0};
};

// ---------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------

// Extract a `--flag=PATH` (or `--flag PATH`) argument from a parsed
// argv. Returns the empty wstring if not found. Quotes are stripped
// from the returned value. Helper used by both --video and --cursor.
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

// Parse both --video and --cursor in one pass over the command line.
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

// Convert QPC ticks delta to milliseconds. Cached frequency so the
// hot path stays cheap.
double TicksToMs(std::int64_t ticks) {
  static const double freq = []() {
    LARGE_INTEGER v{};
    ::QueryPerformanceFrequency(&v);
    return static_cast<double>(v.QuadPart);
  }();
  return freq > 0 ? (static_cast<double>(ticks) * 1000.0) / freq : 0.0;
}

// Print STAGE1B_STATS (cursor_mode == false) or four STAGE1C_STATS
// lines (cursor_mode == true) to stderr, once.
void PrintStatsOnce(DemoState& state) {
  bool expected = false;
  if (!state.stats_printed.compare_exchange_strong(expected, true)) {
    return;
  }
  using clingfy::preview::FrameTimingCollector;
  if (!state.cursor_mode) {
    const auto stats = state.timing_total.ComputeStats();
    const auto line = FrameTimingCollector::FormatStats(stats);
    std::fprintf(stderr, "STAGE1B_STATS %s  dropped=%llu\n", line.c_str(),
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

// ---------------------------------------------------------------------
// D3D11 / D2D setup (unchanged from 1B)
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

HRESULT EnsureHighlightBrush(DemoState& s) {
  if (s.highlight_brush) return S_OK;
  // Two-stop radial gradient: warm yellow at the center, transparent
  // at the rim. The brush is reused every frame; only its center +
  // opacity change.
  D2D1_GRADIENT_STOP stops[2] = {
      {0.0f, D2D1::ColorF(1.0f, 0.95f, 0.55f, 0.85f)},
      {1.0f, D2D1::ColorF(1.0f, 0.95f, 0.55f, 0.0f)},
  };
  ComPtr<ID2D1GradientStopCollection> collection;
  HRESULT hr = s.d2d_context->CreateGradientStopCollection(
      stops, 2, collection.GetAddressOf());
  if (FAILED(hr)) return hr;
  D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES props{};
  props.center = D2D1::Point2F(0.0f, 0.0f);
  props.gradientOriginOffset = D2D1::Point2F(0.0f, 0.0f);
  props.radiusX = kHighlightRadiusPx;
  props.radiusY = kHighlightRadiusPx;
  return s.d2d_context->CreateRadialGradientBrush(
      props, collection.Get(),
      s.highlight_brush.ReleaseAndGetAddressOf());
}

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

  hr = s.d2d_context->CreateSolidColorBrush(
      D2D1::ColorF(D2D1::ColorF::Black),
      s.black_brush.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;
  return EnsureHighlightBrush(s);
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

HRESULT EnsureVideoTarget(DemoState& s, UINT vw, UINT vh) {
  if (vw == 0 || vh == 0) return E_INVALIDARG;
  if (s.video_texture && s.video_width == vw && s.video_height == vh) {
    return S_OK;
  }
  s.video_bitmap.Reset();
  s.video_texture.Reset();
  s.winrt_video_surface = nullptr;

  D3D11_TEXTURE2D_DESC td{};
  td.Width = vw;
  td.Height = vh;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = s.d3d_device->CreateTexture2D(
      &td, nullptr, s.video_texture.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  ComPtr<IDXGISurface> dxgi_surface;
  hr = s.video_texture.As(&dxgi_surface);
  if (FAILED(hr)) return hr;
  ComPtr<::IInspectable> inspectable;
  hr = ::CreateDirect3D11SurfaceFromDXGISurface(
      dxgi_surface.Get(),
      reinterpret_cast<::IInspectable**>(inspectable.GetAddressOf()));
  if (FAILED(hr)) return hr;
  winrt::com_ptr<::IInspectable> winrt_inspectable;
  winrt_inspectable.attach(inspectable.Detach());
  s.winrt_video_surface =
      winrt_inspectable.as<winrt_dxd3d::IDirect3DSurface>();

  const auto props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_NONE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_IGNORE));
  hr = s.d2d_context->CreateBitmapFromDxgiSurface(
      dxgi_surface.Get(), &props,
      s.video_bitmap.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  s.video_width = vw;
  s.video_height = vh;
  return S_OK;
}

// ---------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------

D2D1_RECT_F LetterboxRect(UINT win_w, UINT win_h, UINT vid_w, UINT vid_h) {
  if (win_w == 0 || win_h == 0 || vid_w == 0 || vid_h == 0) {
    return {0, 0, static_cast<float>(win_w), static_cast<float>(win_h)};
  }
  const double win_ratio = static_cast<double>(win_w) / win_h;
  const double vid_ratio = static_cast<double>(vid_w) / vid_h;
  double draw_w = 0, draw_h = 0;
  if (vid_ratio > win_ratio) {
    draw_w = win_w;
    draw_h = win_w / vid_ratio;
  } else {
    draw_h = win_h;
    draw_w = win_h * vid_ratio;
  }
  const double left = (win_w - draw_w) * 0.5;
  const double top = (win_h - draw_h) * 0.5;
  return {static_cast<float>(left), static_cast<float>(top),
          static_cast<float>(left + draw_w),
          static_cast<float>(top + draw_h)};
}

// Map a point in video-pixel space to a point in back-buffer pixel
// space, given the letterboxed dest rect that the video unscaled would
// occupy.
D2D1_POINT_2F VideoToBackBuffer(double vx, double vy, UINT vid_w,
                                UINT vid_h, const D2D1_RECT_F& dest) {
  if (vid_w == 0 || vid_h == 0) return D2D1::Point2F(0.0f, 0.0f);
  const float dx = dest.right - dest.left;
  const float dy = dest.bottom - dest.top;
  const float ox =
      dest.left + static_cast<float>(vx / vid_w) * dx;
  const float oy =
      dest.top + static_cast<float>(vy / vid_h) * dy;
  return D2D1::Point2F(ox, oy);
}

// Compute the zoom destination rect on the back buffer. The "focus"
// point in back-buffer pixels is held fixed under the zoom so the
// cursor pixel in the source video stays exactly where it would have
// been at zoom=1.0. zoom_factor=1.0 returns `dest` unchanged.
D2D1_RECT_F ZoomedDestRect(const D2D1_RECT_F& dest, float focus_x,
                           float focus_y, float zoom_factor) {
  if (zoom_factor <= 1.0f + 1e-4f) return dest;
  const float left =
      focus_x - (focus_x - dest.left) * zoom_factor;
  const float top =
      focus_y - (focus_y - dest.top) * zoom_factor;
  const float width = (dest.right - dest.left) * zoom_factor;
  const float height = (dest.bottom - dest.top) * zoom_factor;
  return {left, top, left + width, top + height};
}

// ---------------------------------------------------------------------
// Per-frame composition
// ---------------------------------------------------------------------

// Returns the playback position in microseconds, or -1 if unavailable.
std::int64_t CurrentPlaybackUs(winrt_playback::MediaPlayer const& player) {
  try {
    const auto pos = player.PlaybackSession().Position();
    return std::chrono::duration_cast<std::chrono::microseconds>(pos)
        .count();
  } catch (winrt::hresult_error const&) {
    return -1;
  }
}

void HandleVideoFrameAvailable(DemoState& s,
                               winrt_playback::MediaPlayer const& sender) {
  if (s.shutting_down.load()) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  // Total bucket bracket — entire callback work.
  const std::int64_t t_start = QpcTicks();
  s.timing_total.BeginFrame();

  std::lock_guard<std::mutex> lock(s.render_mutex);
  if (!s.swap_chain || !s.backbuffer_bitmap) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing_total.EndFrame();
    return;
  }

  const auto session = sender.PlaybackSession();
  const UINT vw = session.NaturalVideoWidth();
  const UINT vh = session.NaturalVideoHeight();
  if (vw == 0 || vh == 0) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing_total.EndFrame();
    return;
  }
  if (FAILED(EnsureVideoTarget(s, vw, vh))) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing_total.EndFrame();
    return;
  }

  // ---- Copy bucket: CopyFrameToVideoSurface ----
  const std::int64_t t_before_copy = QpcTicks();
  if (s.cursor_mode) s.timing_copy.BeginFrame();
  try {
    sender.CopyFrameToVideoSurface(s.winrt_video_surface);
  } catch (winrt::hresult_error const&) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    if (s.cursor_mode) s.timing_copy.EndFrame();
    s.timing_total.EndFrame();
    return;
  }
  if (s.cursor_mode) s.timing_copy.EndFrame();
  (void)t_before_copy;

  // ---- Zoom state machine (only when cursor data is loaded) ----
  float cursor_back_x = 0.0f, cursor_back_y = 0.0f;
  float highlight_alpha = 0.0f;
  float zoom_for_draw = 1.0f;
  const D2D1_RECT_F dest = LetterboxRect(s.client_width, s.client_height,
                                         s.video_width, s.video_height);

  if (s.cursor_mode) {
    using namespace clingfy::preview;
    const std::int64_t playback_us = CurrentPlaybackUs(sender);
    const CursorEvent* nearest =
        FindNearestCursor(s.cursor_events, playback_us);
    const CursorEvent* click = FindNearestClick(
        s.cursor_events, playback_us, kClickLookupWindowUs);

    // Position target follows the nearest cursor sample.
    if (nearest != nullptr) {
      s.zoom.target_x = nearest->x;
      s.zoom.target_y = nearest->y;
    }
    // Zoom target: if a click was recent OR we're still inside the
    // minimum-on hold from the last click, keep target zoomed in.
    const std::int64_t now_us = playback_us;
    const std::int64_t hold_us = static_cast<std::int64_t>(
        kZoomMinOnSeconds * 1'000'000.0);
    bool zoom_wanted = false;
    if (click != nullptr) {
      // A click is recent → trigger / refresh the hold.
      s.zoom.last_click_ts_us =
          std::max(s.zoom.last_click_ts_us, click->ts_us);
      zoom_wanted = true;
    } else if (s.zoom.last_click_ts_us !=
                   std::numeric_limits<std::int64_t>::min() &&
               now_us >= 0 &&
               (now_us - s.zoom.last_click_ts_us) < hold_us) {
      // Inside the post-click hold window.
      zoom_wanted = true;
    }
    s.zoom.target_zoom =
        zoom_wanted ? kZoomFactorDefault : 1.0;

    // Smoother step.
    StepZoomSmoother(s.zoom, NowSeconds());

    const float zf = static_cast<float>(s.zoom.current_zoom);
    zoom_for_draw = zf;
    const auto cursor_bb = VideoToBackBuffer(
        s.zoom.current_x, s.zoom.current_y, s.video_width,
        s.video_height, dest);
    cursor_back_x = cursor_bb.x;
    cursor_back_y = cursor_bb.y;
    // Highlight fades in linearly with zoom magnitude across the
    // smoother range [1.0, kZoomFactorDefault]. At rest (zoom == 1.0)
    // the halo is invisible, matching the macOS "no overlay between
    // zoom segments" feel.
    const double span = kZoomFactorDefault - 1.0;
    const double t = span > 0 ? (s.zoom.current_zoom - 1.0) / span : 0.0;
    highlight_alpha = static_cast<float>(std::clamp(t, 0.0, 1.0));
  }

  // ---- Render bucket: D2D BeginDraw → DrawBitmap → optional
  //                     highlight → EndDraw ----
  if (s.cursor_mode) s.timing_render.BeginFrame();
  s.d2d_context->BeginDraw();
  s.d2d_context->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 1.0f));

  const auto zoomed_dest = s.cursor_mode
                               ? ZoomedDestRect(dest, cursor_back_x,
                                                cursor_back_y,
                                                zoom_for_draw)
                               : dest;
  s.d2d_context->DrawBitmap(s.video_bitmap.Get(), &zoomed_dest, 1.0f,
                            D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);

  if (s.cursor_mode && s.highlight_brush && highlight_alpha > 0.0f) {
    s.highlight_brush->SetCenter(
        D2D1::Point2F(cursor_back_x, cursor_back_y));
    s.highlight_brush->SetOpacity(highlight_alpha);
    const D2D1_ELLIPSE halo = {
        D2D1::Point2F(cursor_back_x, cursor_back_y),
        kHighlightRadiusPx, kHighlightRadiusPx};
    s.d2d_context->FillEllipse(halo, s.highlight_brush.Get());
  }

  const HRESULT end_hr = s.d2d_context->EndDraw();
  if (end_hr == D2DERR_RECREATE_TARGET) {
    BindBackBuffer(s);
  }
  if (s.cursor_mode) s.timing_render.EndFrame();

  // ---- Present bucket ----
  if (s.cursor_mode) s.timing_present.BeginFrame();
  s.swap_chain->Present(0, 0);
  if (s.cursor_mode) s.timing_present.EndFrame();

  s.timing_total.EndFrame();
  (void)t_start;
}

// ---------------------------------------------------------------------
// Win32 plumbing
// ---------------------------------------------------------------------

LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                            LPARAM lparam) {
  auto* state = reinterpret_cast<DemoState*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_CREATE: {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
      return 0;
    }
    case WM_SIZE: {
      if (state && state->swap_chain) {
        const UINT w = LOWORD(lparam);
        const UINT h = HIWORD(lparam);
        if (w > 0 && h > 0) {
          ResizeSwapChain(*state, w, h);
        }
      }
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      ::BeginPaint(hwnd, &ps);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_CLOSE: {
      if (state) PrintStatsOnce(*state);
      ::DestroyWindow(hwnd);
      return 0;
    }
    case WM_DESTROY: {
      if (state) PrintStatsOnce(*state);
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

  // ---- 2. Init COM apartment ----
  winrt::init_apartment(winrt::apartment_type::single_threaded);

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
    state.cursor_events = LoadCursorJsonl(paths.cursor);
    state.cursor_mode = !state.cursor_events.empty();
    if (!state.cursor_mode) {
      // The path existed and the user clearly meant to enable cursor
      // mode, but we got nothing parseable out. Tell the operator;
      // don't silently fall back to video-only.
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
    // Best-effort. Stats already printed by WM_DESTROY.
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
