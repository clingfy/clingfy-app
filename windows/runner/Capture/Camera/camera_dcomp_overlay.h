#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_OVERLAY_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_OVERLAY_H_

#include <d2d1_1.h>
#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_2.h>
#include <windows.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

#include "Capture/Camera/camera_bubble_painter.h"
#include "Capture/Camera/camera_overlay_presenter.h"

// Renderer redesign P3 — the DirectComposition presenter for the floating
// camera bubble (docs/decisions/windows-camera-bubble-renderer-architecture.md).
//
// A WS_EX_NOREDIRECTIONBITMAP topmost tool window whose content is a
// premultiplied-alpha DXGI composition swapchain (B8G8R8A8 / FLIP_SEQUENTIAL /
// DXGI_SCALING_STRETCH) attached through a DirectComposition visual — the exact
// stack PowerToys MeasureTool ships. Direct2D draws the bubble through the
// SHARED CameraBubblePainter (the export / inline-preview effects core), so the
// live bubble renders opacity / shadow / chroma / mirror / shape / border
// WYSIWYG with the export by construction — everything the opaque GDI
// presenter cannot.
//
// Geometry model: a SQUARE window of side `size` (ComputeSquareFloatingRect) —
// the macOS bubble-window model and the painter's native assumption. The GDI
// fallback keeps its legacy 16:9 shape.
//
// Same lifecycle contract as CameraFloatingOverlay: own thread + message pump
// (all GPU objects live on it), created HIDDEN, capture-excluded via
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) — the engine never Show()s a
// presenter whose exclusion failed. Exclusion is best-effort by OS design (a
// documented Win11 defect fails the call outright, disproportionately for
// DComp-presented windows) — the factory falls back to the GDI presenter when
// it fails here.
//
// P4a: the window outsizes the content square by an effect-padding halo
// (ComputeCameraEffectPadding — border/shadow/glow are never clipped at the
// window edge), placement keeps the CONTENT at the work-area margins
// (ComputePaddedSquareFloatingRect), and WM_NCHITTEST makes the halo
// click-through (HTTRANSPARENT) while the content square stays the drag
// handle (macOS hitTest parity). Window size now depends on the STYLE store
// too (padding follows border width / shadow preset / glow), so the sync tick
// re-places the window on style revisions as well.
// Still deferred: glow ring + pulse (P4b); WM_DPICHANGED, device-lost
// rebuild, mid-session fallback, capture-display retarget (P4c); default
// flip (P4d).
namespace clingfy::capture {

class CameraDcompOverlay : public ICameraOverlayPresenter {
 public:
  struct Options {
    // Tests only: the render-path probe needs a window WITHOUT capture
    // exclusion (every capture API respects the exclusion, so a excluded
    // window is invisible to the probe by design).
    bool apply_capture_exclusion = true;
  };

  CameraDcompOverlay() = default;
  explicit CameraDcompOverlay(const Options& options) : options_(options) {}
  ~CameraDcompOverlay() override;

  CameraDcompOverlay(const CameraDcompOverlay&) = delete;
  CameraDcompOverlay& operator=(const CameraDcompOverlay&) = delete;

  // ICameraOverlayPresenter. Start additionally fails (returns false) when the
  // GPU stack (D3D device / composition swapchain / D2D / DComp) cannot be
  // built — the factory then falls back to the GDI presenter.
  bool Start(const FloatingPlacement& placement) override;
  void Show() override;
  void Hide() override;
  void PublishBgra(const std::uint8_t* bgra, int width, int height) override;
  void Stop() override;
  bool running() const override { return running_.load(); }
  bool wda_excluded() const override { return wda_excluded_.load(); }

  // POC-gate introspection: true once the full GPU stack is up.
  bool gpu_ready() const { return gpu_ready_.load(); }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  void ThreadMain(FloatingPlacement placement, std::promise<bool>* ready);
  // Build device -> composition swapchain (w x h px) -> D2D context/target ->
  // DComp visual tree. Overlay thread only.
  bool BuildGpuStack(HWND hwnd, int width, int height);
  // Re-size the swapchain buffers (all backbuffer references must drop first)
  // and re-wrap the D2D target.
  bool ResizeSwapchain(int width, int height);
  // Timer tick: apply store geometry (square rect; SetWindowPos + swapchain
  // resize) and style (painter re-Prepare) changes, then redraw if needed.
  void SyncAndRender(HWND hwnd);
  // Cursor-tracked halo click-through (P4a): flips ONLY the WS_EX_TRANSPARENT
  // bit when the cursor crosses the content/halo boundary (HTTRANSPARENT alone
  // cannot fall through to other threads' windows), then re-verifies the
  // capture exclusion — a mutation that silently drops WDA hides the bubble.
  void UpdateHaloClickThrough(HWND hwnd);
  // Re-Prepare the shared painter for the current style snapshot + camera
  // dims, drawing into the content square at (padding_px, padding_px) so
  // border/shadow/glow spill into the halo instead of the window edge. MUST
  // run outside BeginDraw (shadow bake does SetTarget round-trips); re-binds
  // the swapchain target afterwards.
  bool PreparePainter(int content_side, int padding_px);
  void OnDragEnded(HWND hwnd);
  // Release every GPU-stack member (painter, bitmaps, D2D, DComp, swapchain,
  // device) in dependency order. Overlay thread only — shared by the normal
  // teardown and the BuildGpuStack-failure path, so partially-built COM state
  // never escapes to be released on another thread.
  void ReleaseGpuStack();

  Options options_{};

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> wda_excluded_{false};
  std::atomic<bool> gpu_ready_{false};
  std::atomic<HWND> hwnd_{nullptr};
  DWORD thread_id_ = 0;

  // Frame mailbox (capture thread -> overlay thread), same as the GDI
  // presenter: the producer's buffer is reused, so it is copied here.
  std::mutex frame_mutex_;
  std::vector<std::uint8_t> frame_bgra_;
  int frame_w_ = 0;
  int frame_h_ = 0;
  bool dirty_ = false;

  // GPU stack — created and used exclusively on the overlay thread.
  Microsoft::WRL::ComPtr<ID3D11Device> d3d_device_;
  Microsoft::WRL::ComPtr<IDXGISwapChain1> swapchain_;
  Microsoft::WRL::ComPtr<ID2D1Factory1> d2d_factory_;
  Microsoft::WRL::ComPtr<ID2D1Device> d2d_device_;
  Microsoft::WRL::ComPtr<ID2D1DeviceContext> d2d_ctx_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> target_bitmap_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> camera_bitmap_;
  Microsoft::WRL::ComPtr<IDCompositionDevice> dcomp_device_;
  Microsoft::WRL::ComPtr<IDCompositionTarget> dcomp_target_;
  Microsoft::WRL::ComPtr<IDCompositionVisual> dcomp_visual_;

  // Painter + the state it was prepared for — overlay thread only.
  CameraBubblePainter painter_;
  bool painter_ready_ = false;
  std::uint64_t last_style_revision_ = ~0ull;   // force first sync
  std::uint64_t last_geometry_revision_ = ~0ull;
  // Window/content split (P4a): the swapchain covers the whole padded window;
  // the painter draws into the content square at (padding, padding). Written
  // on the overlay thread (creation + sync tick) and read by WM_NCHITTEST,
  // which also runs on the overlay thread.
  int prepared_window_side_ = 0;
  int prepared_content_side_ = 0;
  int prepared_padding_px_ = 0;
  // Whether WS_EX_TRANSPARENT is currently set (cursor off-content). Overlay
  // thread only.
  bool click_through_ = false;
  // Inside the OS modal move loop (WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE): the
  // sync tick defers store-driven SetWindowPos so it never fights the user's
  // grab. Overlay thread only.
  bool in_size_move_ = false;
  int prepared_cam_w_ = 0;
  int prepared_cam_h_ = 0;
  bool render_failed_logged_ = false;
  bool first_present_logged_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_OVERLAY_H_
