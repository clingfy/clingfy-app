#include "Preview/preview_camera_renderer.h"

#include <mfapi.h>
#include <mferror.h>

#include <utility>

#include "Capture/Camera/camera_export_layout.h"

namespace clingfy::preview {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

}  // namespace

bool PreviewCameraShouldSeek(std::int64_t camera_hns, std::int64_t held_pts_hns,
                             bool has_held_frame) {
  if (!has_held_frame && held_pts_hns < 0) {
    // Cold start: only seek if the target is far enough in to be worth it (else
    // decoding from the file start is cheap and avoids a key-frame jump).
    return camera_hns > kPreviewCameraSeekThresholdHns;
  }
  return camera_hns < held_pts_hns ||
         camera_hns - held_pts_hns > kPreviewCameraSeekThresholdHns;
}

std::unique_ptr<PreviewCameraRenderer> PreviewCameraRenderer::Create(
    const std::wstring& camera_path, std::int64_t start_offset_ms) {
  if (camera_path.empty()) {
    return nullptr;
  }

  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 1))) {
    return nullptr;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(camera_path.c_str(), attrs.Get(),
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return nullptr;
  }

  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  if (FAILED(reader->SetStreamSelection(kFirstVideoStream, TRUE))) {
    return nullptr;
  }

  ComPtr<IMFMediaType> rgb_type;
  if (FAILED(::MFCreateMediaType(rgb_type.GetAddressOf()))) {
    return nullptr;
  }
  rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(kFirstVideoStream, nullptr,
                                         rgb_type.Get()))) {
    return nullptr;
  }

  UINT32 w = 0;
  UINT32 h = 0;
  {
    ComPtr<IMFMediaType> current;
    if (FAILED(reader->GetCurrentMediaType(kFirstVideoStream,
                                           current.GetAddressOf())) ||
        FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
        w == 0 || h == 0) {
      return nullptr;
    }
  }

  auto renderer =
      std::unique_ptr<PreviewCameraRenderer>(new PreviewCameraRenderer());
  renderer->reader_ = std::move(reader);
  renderer->stream_index_ = kFirstVideoStream;
  renderer->cam_w_ = w;
  renderer->cam_h_ = h;
  renderer->start_offset_ms_ = start_offset_ms;
  return renderer;
}

void PreviewCameraRenderer::SetComposition(
    const PreviewCameraComposition& composition) {
  std::lock_guard<std::mutex> lock(mutex_);
  composition_ = composition;
  dirty_ = true;
}

bool PreviewCameraRenderer::UploadSample(IMFSample* sample) {
  if (sample == nullptr || frame_bitmap_ == nullptr) {
    return false;
  }
  if (!clingfy::capture::ExtractCameraFrameBgra(sample, cam_w_, cam_h_,
                                                &scratch_)) {
    return false;
  }
  return SUCCEEDED(frame_bitmap_->CopyFromMemory(
      nullptr, scratch_.data(), static_cast<UINT32>(cam_w_) * 4u));
}

void PreviewCameraRenderer::SeekTo(std::int64_t camera_hns) {
  PROPVARIANT pos;
  PropVariantInit(&pos);
  pos.vt = VT_I8;
  pos.hVal.QuadPart = camera_hns < 0 ? 0 : camera_hns;
  reader_->SetCurrentPosition(GUID_NULL, pos);
  PropVariantClear(&pos);
  // Reset the whole decode cursor; the held frame is re-pulled from the seek
  // point and the parked future frame (from before the seek) is discarded.
  eos_ = false;
  has_pending_ = false;
  pending_sample_.Reset();
  has_held_frame_ = false;
  held_pts_hns_ = -1;
}

void PreviewCameraRenderer::PullForward(std::int64_t camera_hns) {
  // Hold the latest frame whose pts is <= camera_hns. A peeked future frame is
  // PARKED in pending_sample_ (the reader can't push back), so the next call
  // re-evaluates it instead of skipping it, and a paused position (constant
  // camera_hns) does no work once the pending frame is in the future.
  while (!eos_) {
    if (has_pending_) {
      if (pending_pts_hns_ <= camera_hns) {
        if (UploadSample(pending_sample_.Get())) {
          has_held_frame_ = true;
          held_pts_hns_ = pending_pts_hns_;
        }
        has_pending_ = false;
        pending_sample_.Reset();
        continue;
      }
      break;  // pending frame is in the future; the held frame is current
    }
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    const HRESULT hr = reader_->ReadSample(stream_index_, 0, nullptr, &flags,
                                           &ts, sample.GetAddressOf());
    if (FAILED(hr)) {
      eos_ = true;
      break;
    }
    if (sample != nullptr) {
      pending_sample_ = std::move(sample);
      pending_pts_hns_ = static_cast<std::int64_t>(ts);
      has_pending_ = true;
      continue;  // re-evaluate against camera_hns
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      eos_ = true;
      break;
    }
    continue;  // stream tick (gap / format change)
  }
}

void PreviewCameraRenderer::PrepareAndAdvance(ID2D1DeviceContext* ctx,
                                              UINT canvas_w, UINT canvas_h,
                                              std::int64_t playback_us) {
  if (ctx == nullptr || canvas_w == 0 || canvas_h == 0) {
    return;
  }

  // Snapshot the pending composition.
  PreviewCameraComposition comp;
  bool needs_rebuild = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    comp = composition_;
    needs_rebuild = dirty_ || canvas_w != prepared_canvas_w_ ||
                    canvas_h != prepared_canvas_h_;
    dirty_ = false;
  }
  composition_visible_ = comp.visible;
  if (!comp.visible) {
    return;  // camera hidden → nothing to prepare or draw
  }

  // (Re)build the painter when the composition or the canvas changed. Done here,
  // OUTSIDE the engine's BeginDraw (the shadow bake does SetTarget round-trips).
  if (needs_rebuild || !painter_ready_) {
    ComPtr<ID2D1Factory> factory0;
    ctx->GetFactory(factory0.GetAddressOf());
    ComPtr<ID2D1Factory1> factory1;
    if (factory0 != nullptr) {
      factory0.As(&factory1);
    }
    if (frame_bitmap_ == nullptr) {
      const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_NONE,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
      ctx->CreateBitmap(D2D1::SizeU(cam_w_, cam_h_), nullptr, 0, props,
                        frame_bitmap_.GetAddressOf());
    }
    painter_ready_ = false;
    if (factory1 != nullptr && frame_bitmap_ != nullptr) {
      const clingfy::capture::CameraBubbleRect bubble =
          clingfy::capture::ComputeCameraBubbleRect(
              static_cast<double>(canvas_w), static_cast<double>(canvas_h),
              comp.has_center, comp.center_x, comp.center_y, comp.layout_preset,
              comp.size_factor);
      clingfy::capture::CameraBubblePainter::Style style;
      style.mirror = comp.mirror;
      style.opacity = comp.opacity;
      style.border_width = comp.border_width;
      style.has_border_color = comp.has_border_color;
      style.border_argb = comp.border_argb;
      style.shadow_preset = comp.shadow_preset;
      painter_ready_ = painter_.Prepare(factory1.Get(), ctx, bubble, comp.shape,
                                        comp.corner_radius, comp.content_mode,
                                        style, cam_w_, cam_h_);
    }
    prepared_canvas_w_ = canvas_w;
    prepared_canvas_h_ = canvas_h;
  }

  // Advance the held camera frame to the playback position.
  const std::int64_t camera_hns =
      static_cast<std::int64_t>(playback_us) * 10 - start_offset_ms_ * 10000;
  if (camera_hns < 0) {
    // Before the camera's first frame: show nothing, and reset the decode cursor
    // so crossing back into the camera window is a clean cold start (cold-start
    // seek logic relies on held_pts_hns_ < 0).
    has_held_frame_ = false;
    held_pts_hns_ = -1;
    has_pending_ = false;
    pending_sample_.Reset();
    return;
  }
  // Seek on a backward jump, a large forward jump (scrub), or a far cold start;
  // else pull forward through the next few decoded frames.
  if (PreviewCameraShouldSeek(camera_hns, held_pts_hns_, has_held_frame_)) {
    SeekTo(camera_hns);
  }
  PullForward(camera_hns);
}

void PreviewCameraRenderer::Draw(ID2D1DeviceContext* ctx) {
  if (!composition_visible_ || !painter_ready_ || !has_held_frame_) {
    return;
  }
  painter_.Draw(ctx, frame_bitmap_.Get());
}

}  // namespace clingfy::preview
