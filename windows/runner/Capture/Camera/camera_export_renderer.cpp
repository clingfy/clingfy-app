#include "Capture/Camera/camera_export_renderer.h"

#include <mfapi.h>
#include <mferror.h>
#include <propidl.h>

#include <algorithm>
#include <utility>

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

}  // namespace

std::unique_ptr<CameraExportRenderer> CameraExportRenderer::Create(
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
      std::unique_ptr<CameraExportRenderer>(new CameraExportRenderer());
  renderer->reader_ = std::move(reader);
  renderer->stream_index_ = kFirstVideoStream;
  renderer->cam_w_ = w;
  renderer->cam_h_ = h;
  renderer->start_offset_ms_ = start_offset_ms;
  return renderer;
}

bool CameraExportRenderer::Prepare(ID2D1Factory1* factory,
                                   ID2D1DeviceContext* ctx,
                                   const CameraBubbleRect& bubble,
                                   const std::string& shape,
                                   double corner_radius,
                                   const std::string& content_mode,
                                   const Style& style,
                                   const CameraAnimationParams& anim,
                                   double canvas_w, double canvas_h,
                                   CameraSlideEdge slide_edge,
                                   const std::string& zoom_behavior,
                                   double zoom_scale_multiplier,
                                   const std::string& layout_preset) {
  if (factory == nullptr || ctx == nullptr || cam_w_ == 0 || cam_h_ == 0) {
    return false;
  }

  anim_params_ = anim;
  bubble_ = bubble;
  canvas_w_ = canvas_w;
  canvas_h_ = canvas_h;
  slide_edge_ = slide_edge;
  zoom_behavior_ = zoom_behavior;
  zoom_scale_multiplier_ = zoom_scale_multiplier;
  layout_preset_ = layout_preset;

  // Source bitmap holds the latest decoded camera frame (system-memory upload).
  const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_NONE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(cam_w_, cam_h_), nullptr, 0, props,
                               frame_bitmap_.GetAddressOf()))) {
    return false;
  }

  if (!painter_.Prepare(factory, ctx, bubble, shape, corner_radius,
                        content_mode, style, cam_w_, cam_h_)) {
    return false;
  }

  ready_ = true;
  return true;
}

bool CameraExportRenderer::UploadSample(IMFSample* sample) {
  if (sample == nullptr || frame_bitmap_ == nullptr) {
    return false;
  }
  if (!ExtractCameraFrameBgra(sample, cam_w_, cam_h_, &scratch_)) {
    return false;
  }
  return SUCCEEDED(frame_bitmap_->CopyFromMemory(
      nullptr, scratch_.data(), static_cast<UINT32>(cam_w_) * 4u));
}

void CameraExportRenderer::Advance(std::int64_t frame_ms) {
  if (!ready_) {
    return;
  }

  const std::int64_t camera_ms =
      CameraTimeMsForFrame(frame_ms, start_offset_ms_);
  if (camera_ms < 0) {
    return;  // the camera hadn't started yet at this point in the recording
  }
  const std::int64_t camera_hns = camera_ms * 10000;

  while (!eos_) {
    if (has_pending_) {
      if (pending_pts_hns_ <= camera_hns) {
        if (UploadSample(pending_sample_.Get())) {
          has_held_frame_ = true;
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
      // A source may deliver its final frame WITH the end-of-stream flag set on
      // the same call; park it as pending and let the loop evaluate it.
      pending_sample_ = std::move(sample);
      pending_pts_hns_ = static_cast<std::int64_t>(ts);
      has_pending_ = true;
      continue;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      eos_ = true;
      break;
    }
    continue;  // stream tick (gap / format change)
  }
}

void CameraExportRenderer::SeekTo(std::int64_t frame_ms) {
  if (!ready_ || reader_ == nullptr) {
    return;
  }
  const std::int64_t camera_ms =
      CameraTimeMsForFrame(frame_ms, start_offset_ms_);
  PROPVARIANT pos;
  PropVariantInit(&pos);
  pos.vt = VT_I8;
  // A pre-start target (camera hadn't begun yet) clamps to 0; the next Advance
  // will no-op until the camera's own timeline is reached, as before.
  pos.hVal.QuadPart = std::max<std::int64_t>(0, camera_ms) * 10000;
  if (SUCCEEDED(reader_->SetCurrentPosition(GUID_NULL, pos))) {
    // Drop the forward-pull state so the next Advance re-reads from the seek
    // point. The held frame + its bitmap survive as a fallback until Advance
    // uploads a new one, so a Draw between SeekTo and Advance never blanks.
    has_pending_ = false;
    pending_sample_.Reset();
    eos_ = false;
  }
  PropVariantClear(&pos);
}

void CameraExportRenderer::Draw(ID2D1DeviceContext* ctx,
                                std::int64_t frame_ms,
                                std::int64_t total_duration_ms,
                                double screen_zoom) {
  if (!ready_ || !has_held_frame_) {
    return;
  }
  CameraAnimationParams params = anim_params_;
  params.zoom_scale = ResolveCameraZoomScale(
      zoom_behavior_, zoom_scale_multiplier_, screen_zoom, layout_preset_);
  const CameraAnimationOutput a =
      ResolveCameraAnimation(params, frame_ms, total_duration_ms, bubble_,
                             canvas_w_, canvas_h_, slide_edge_);
  CameraBubblePainter::Frame frame;
  frame.opacity_mul = a.opacity;
  frame.scale = a.scale;
  frame.translate_x = a.translate_x;
  frame.translate_y = a.translate_y;
  painter_.Draw(ctx, frame_bitmap_.Get(), frame);
}

}  // namespace clingfy::capture
