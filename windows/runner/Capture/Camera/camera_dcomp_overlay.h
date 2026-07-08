#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_OVERLAY_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_OVERLAY_H_

#include <d2d1_1.h>
#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_2.h>
#include <windows.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
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
// P4b: the recording glow ring — presenter-drawn on top of the painter's
// output (LIVE-ONLY; never in the shared painter, which would bake it into
// exports). The ring + its blurred halo are baked once per style/geometry
// change (BakeCameraGlowBitmap) and drawn per tick with the macOS pulse
// opacity (CameraGlowPulseOpacity); while glow is active and the window is
// visible, every tick redraws so the pulse animates even when camera frames
// stall. Glow reads the style store's glow fields directly — deliberately
// NOT part of ResolveOverlayBubbleStyle.
// Still deferred: WM_DPICHANGED, device-lost rebuild, mid-session fallback,
// capture-display retarget (P4c); default flip (P4d).
namespace clingfy::capture {

class CameraDcompOverlay : public ICameraOverlayPresenter {
 public:
  struct Options {
    // Tests only: the render-path probe needs a window WITHOUT capture
    // exclusion (every capture API respects the exclusion, so a excluded
    // window is invisible to the probe by design).
    bool apply_capture_exclusion = true;
    // Tests only (P4c): inject `n` simulated device-lost events on the first
    // `n` draws, so the device-lost rebuild path is exercised without real
    // GPU removal. Each injection makes SyncAndRender treat that tick's draw
    // as DXGI_ERROR_DEVICE_REMOVED and rebuild; the bubble must recover.
    int simulate_device_loss_count = 0;
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

  // Test introspection (P4c): total device-loss recovery ATTEMPTS since Start
  // (monotonic; distinct from the consecutive streak that resets on a clean
  // present). Overlay thread writes it; read after Stop for a race-free value.
  int device_loss_attempts() const { return total_device_losses_; }
  // Test introspection (P4c): the presenter has spent its rebuild budget and
  // parked (stack dropped, thread alive) awaiting the mid-session GDI fallback.
  bool device_loss_gave_up() const { return device_loss_gave_up_; }
  // Test introspection (P4c): the current consecutive-loss streak (resets to 0
  // on a clean present). Lets a test observe the streak reset between two
  // well-separated losses. Read after Stop for a race-free value.
  int device_loss_streak() const { return consecutive_device_losses_; }

  // Test-only (P4c): inject ONE device loss on the next draw, unlike
  // Options.simulate_device_loss_count which injects on consecutive draws.
  // Lets a test produce a loss -> clean present -> loss cadence so the
  // consecutive-streak reset is observable. Thread-safe.
  void SimulateDeviceLossOnce() { simulate_one_loss_.store(true); }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam);

 private:
  void ThreadMain(FloatingPlacement placement, std::promise<bool>* ready);
  // Build device -> composition swapchain (w x h px) -> D2D context/target ->
  // DComp visual tree. Overlay thread only.
  bool BuildGpuStack(HWND hwnd, int width, int height);
  // Build ONLY the render resources (D3D device, composition swapchain, D2D
  // factory/device/context, wrapped target) — everything that is bound to the
  // D3D device and must be recreated on device loss. The DComp device/target/
  // visual are NOT touched (they are keyed to the HWND, survive D3D loss, and
  // CreateTargetForHwnd cannot run twice for one window). Overlay thread only.
  bool BuildRenderResources(int width, int height);
  // Release the render resources (see BuildRenderResources) while KEEPING the
  // DComp visual tree, so a rebuild can re-SetContent the retained visual.
  void ReleaseRenderResources();
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
  // (Re)bake the glow bitmap for the current style snapshot, or release it
  // when the glow is off. Same call-site contract as PreparePainter (outside
  // BeginDraw; re-binds the swapchain target). Overlay thread only.
  void PrepareGlow(int content_side, int padding_px);
  void OnDragEnded(HWND hwnd);
  // Release every GPU-stack member (painter, bitmaps, D2D, DComp, swapchain,
  // device) in dependency order. Overlay thread only — shared by the normal
  // teardown and the BuildGpuStack-failure path, so partially-built COM state
  // never escapes to be released on another thread.
  void ReleaseGpuStack();
  // Device-lost recovery (P4c): rebuild the D3D-bound render resources on the
  // same window and re-point the RETAINED DComp visual at the fresh swapchain,
  // then arm a full re-Prepare + frame re-upload on the next tick. Capture
  // exclusion is a window property and survives untouched, so it is NOT
  // re-applied. Returns false if the rebuild failed (the caller counts
  // consecutive failures toward the mid-session GDI fallback). Overlay thread.
  bool RebuildGpuStack(HWND hwnd);
  // Apply WDA_EXCLUDEFROMCAPTURE (when options_.apply_capture_exclusion) and
  // record wda_excluded_; logs on failure (the documented Win11 defect). Runs
  // once at initial creation (the render-only rebuild leaves WDA untouched).
  // Overlay thread.
  void ApplyCaptureExclusion(HWND hwnd);
  // One device-loss recovery attempt: count it toward the budget, then rebuild
  // the GPU stack. On rebuild failure, arm a retry for the next tick; past the
  // budget, give up and log the mid-session-fallback hook (c3). Called from
  // the draw path when a device-lost HRESULT is seen, and from the tick top
  // while a retry is armed. Overlay thread only.
  void AttemptDeviceLossRecovery(HWND hwnd, const char* where);

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
  // Glow ring (P4b) — overlay thread only. The baked bitmap carries the full
  // configured alphas; the per-tick draw multiplies in the pulse opacity.
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> glow_bitmap_;
  D2D1_RECT_F glow_dest_{};
  bool glow_active_ = false;
  // Enabled-but-bake-failed: retried every tick (the enabling revision is
  // already consumed) so a transient GPU failure cannot blank the ring.
  bool glow_bake_failed_ = false;
  bool glow_bake_failed_logged_ = false;
  double glow_strength_ = 0.70;
  std::chrono::steady_clock::time_point glow_epoch_{};
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
  // Device-lost recovery (P4c). consecutive_device_losses_ counts back-to-back
  // loss/rebuild attempts (reset on a clean present); past
  // kMaxConsecutiveDeviceLosses the presenter stops rebuilding and logs the
  // mid-session-fallback hook (c3). device_loss_retry_pending_ arms a rebuild
  // retry on the next tick when an in-place rebuild itself failed.
  int consecutive_device_losses_ = 0;
  int total_device_losses_ = 0;  // monotonic; test introspection.
  bool device_loss_retry_pending_ = false;
  bool device_loss_gave_up_ = false;
  bool device_loss_fallback_logged_ = false;
  int simulated_device_losses_remaining_ = 0;
  std::atomic<bool> simulate_one_loss_{false};  // test one-shot injection
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_OVERLAY_H_
