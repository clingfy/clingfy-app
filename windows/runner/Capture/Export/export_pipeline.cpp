#include "Capture/Export/export_pipeline.h"

#include <d3d11.h>
#include <d3d11_4.h>
#include <d2d1_1.h>
#include <d2d1_1helper.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propidl.h>
#include <wrl/client.h>

#include <atomic>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <vector>

#include "Audio/audio_mixer.h"
#include "Capture/Camera/camera_export_layout.h"
#include "Capture/Camera/camera_export_renderer.h"
#include "Capture/Cursor/cursor_export_renderer.h"
#include "Capture/Zoom/zoom_export_controller.h"
#include "Capture/Export/export_audio.h"
#include "Capture/Export/export_format.h"
#include "Capture/Export/export_geometry.h"
#include "Capture/Export/gif_export_policy.h"
#include "Capture/captured_video_frame.h"
#include "Encoding/gif_encoder.h"
#include "Encoding/mf_encoder_config.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture::export_ {

namespace {

using Microsoft::WRL::ComPtr;

// Sentinel for "stream not found" — distinguishable from any concrete
// stream index (which start at 0) and from MF's symbolic selectors.
constexpr DWORD kNoStream = 0xFFFFFFFFu;

// Idempotent MF startup. Mirrors the encoder's pattern: paired with
// MFShutdown only at process exit, so opening an export does not churn
// global MF state. A second independent once_flag (the encoder has its
// own) simply bumps MFStartup's internal refcount, which is harmless.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  std::call_once(flag, [] { ::MFStartup(MF_VERSION, MFSTARTUP_LITE); });
}

RenderResult Failure(std::string message) {
  RenderResult out;
  out.ok = false;
  out.message = std::move(message);
  return out;
}

// Slice 5A: build a cancelled result and remove any partial output file. The
// message contains "cancelled" so the Dart side classifies it as a clean
// cancel (post_processing_controller._isLikelyCancellationMessage), not a
// failure. `destination_path` is UTF-8.
RenderResult Cancelled(const std::string& destination_path) {
  if (!destination_path.empty()) {
    std::error_code ec;
    std::filesystem::remove(std::filesystem::u8path(destination_path), ec);
  }
  RenderResult out;
  out.ok = false;
  out.cancelled = true;
  out.message = "export: cancelled by user";
  return out;
}

std::string Hr(const char* what, HRESULT hr) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), " (hr=0x%08lX)", static_cast<unsigned long>(hr));
  return std::string(what) + buf;
}

// Walk the source's streams, selecting only the first video stream (and
// the first audio stream, if any) and recording their concrete indices.
// Returns kNoStream for a track that is absent.
void IdentifyStreams(IMFSourceReader* reader, DWORD* video_index,
                     DWORD* audio_index) {
  *video_index = kNoStream;
  *audio_index = kNoStream;
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  for (DWORD i = 0;; ++i) {
    ComPtr<IMFMediaType> native;
    const HRESULT hr = reader->GetNativeMediaType(i, 0, native.GetAddressOf());
    if (hr == MF_E_INVALIDSTREAMNUMBER) {
      break;
    }
    if (FAILED(hr) || native == nullptr) {
      continue;
    }
    GUID major = GUID_NULL;
    if (FAILED(native->GetGUID(MF_MT_MAJOR_TYPE, &major))) {
      continue;
    }
    if (major == MFMediaType_Video && *video_index == kNoStream) {
      *video_index = i;
    } else if (major == MFMediaType_Audio && *audio_index == kNoStream) {
      *audio_index = i;
    }
  }
}

// Copy one decoded BGRA video frame into a top-down, tightly-packed
// buffer (`dest`, sized width*4*height) regardless of the source buffer's
// stride sign. IMF2DBuffer::Lock2D hands back a pointer to the top row
// plus a stride that may be negative for bottom-up layouts; indexing by
// `scan0 + row * stride` always walks top-to-bottom either way. Returns
// false on lock failure.
bool ExtractTopDownBgra(IMFSample* sample, UINT width, UINT height,
                        std::vector<BYTE>* dest) {
  const size_t row_bytes = static_cast<size_t>(width) * 4u;
  dest->resize(row_bytes * height);

  ComPtr<IMFMediaBuffer> raw;
  if (FAILED(sample->GetBufferByIndex(0, raw.GetAddressOf())) ||
      raw == nullptr) {
    return false;
  }

  ComPtr<IMF2DBuffer> buffer2d;
  if (SUCCEEDED(raw.As(&buffer2d)) && buffer2d != nullptr) {
    BYTE* scan0 = nullptr;
    LONG stride = 0;
    if (FAILED(buffer2d->Lock2D(&scan0, &stride)) || scan0 == nullptr) {
      return false;
    }
    for (UINT row = 0; row < height; ++row) {
      const BYTE* src_row = scan0 + static_cast<LONG>(row) * stride;
      std::memcpy(dest->data() + row * row_bytes, src_row, row_bytes);
    }
    buffer2d->Unlock2D();
    return true;
  }

  // Fallback: a plain contiguous buffer. Assume a top-down, tightly
  // packed layout (the common case for a Video-Processor RGB32 output).
  ComPtr<IMFMediaBuffer> contiguous;
  if (FAILED(sample->ConvertToContiguousBuffer(contiguous.GetAddressOf())) ||
      contiguous == nullptr) {
    return false;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0;
  DWORD cur_len = 0;
  if (FAILED(contiguous->Lock(&data, &max_len, &cur_len)) || data == nullptr) {
    return false;
  }
  const size_t copy_bytes =
      (cur_len < dest->size()) ? cur_len : dest->size();
  std::memcpy(dest->data(), data, copy_bytes);
  contiguous->Unlock();
  return true;
}

// Slice 4 normalize support: decode the whole audio track once (a second,
// independent source reader, audio-only) and return the peak linear level in
// [0, 1]. Mirrors macOS `estimateAudioPeakLinear`, which likewise opens its
// own reader independent of the render decode. Returns 0.0 when there is no
// audio or it can't be decoded — the caller then skips normalize and falls
// back to the plain user gain. Decodes to the SAME 48 kHz stereo int16 PCM
// the main pass scales, so the measured peak matches what gets scaled.
double MeasureSourceAudioPeak(const std::wstring& source_path,
                              const std::function<bool()>& is_cancelled) {
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(source_path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return 0.0;
  }
  DWORD video_index = kNoStream;
  DWORD audio_index = kNoStream;
  IdentifyStreams(reader.Get(), &video_index, &audio_index);
  if (audio_index == kNoStream) {
    return 0.0;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(audio_index, TRUE);

  ComPtr<IMFMediaType> pcm_type;
  if (FAILED(::MFCreateMediaType(pcm_type.GetAddressOf()))) {
    return 0.0;
  }
  pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  if (FAILED(reader->SetCurrentMediaType(audio_index, nullptr,
                                         pcm_type.Get()))) {
    return 0.0;
  }

  double peak = 0.0;
  for (;;) {
    // Honor cancel during the (whole-track) loudness scan; the main loop's
    // cancel check then aborts the export. Returning the peak-so-far is fine
    // since a cancel discards the export.
    if (is_cancelled && is_cancelled()) {
      break;
    }
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &timestamp,
                                  sample.GetAddressOf()))) {
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) ||
        buffer == nullptr) {
      continue;
    }
    BYTE* data = nullptr;
    DWORD max_len = 0;
    DWORD cur_len = 0;
    if (SUCCEEDED(buffer->Lock(&data, &max_len, &cur_len)) && data != nullptr &&
        cur_len > 0) {
      const std::size_t n = cur_len / sizeof(std::int16_t);
      const double buffer_peak =
          Int16PeakLinear(reinterpret_cast<const std::int16_t*>(data), n);
      if (buffer_peak > peak) {
        peak = buffer_peak;
      }
    }
    if (data != nullptr) {
      buffer->Unlock();
    }
  }
  return peak;
}

}  // namespace

RenderResult RenderComposedExport(const RenderRequest& request) {
  EnsureMediaFoundationStarted();

  // Slice 5A: bail before any heavy GPU/MF setup if already cancelled. No
  // output file exists yet, so Cancelled() just returns the clean result.
  if (request.is_cancelled && request.is_cancelled()) {
    return Cancelled(request.destination_path);
  }

  // Slice 5B: a .gif destination is encoded with the WIC GIF encoder instead of
  // the H.264 Sink Writer. GIF carries no audio and the frame loop decimates to
  // ~kGifTargetFps; everything else (decode, Direct2D composition, progress,
  // cancel) is shared with the video path.
  const bool gif = IsGifDestination(request.destination_path);

  // --- D3D11 device shared by decode-upload, Direct2D, and the encoder.
  clingfy::graphics::D3DDevice device;
  if (auto err = device.Create()) {
    return Failure("export: D3D11 device creation failed — " + err->message);
  }
  // The hardware H.264 MFT runs the encode on its own worker thread, so
  // the device it shares with our Direct2D draws must be multithread
  // protected. Best-effort: older feature levels may not expose the
  // interface, in which case the software path still works.
  {
    ComPtr<ID3D11Multithread> multithread;
    if (SUCCEEDED(device.context()->QueryInterface(
            IID_PPV_ARGS(multithread.GetAddressOf()))) &&
        multithread != nullptr) {
      multithread->SetMultithreadProtected(TRUE);
    }
  }

  // --- Source reader: decode video to BGRA system memory + audio to PCM.
  ComPtr<IMFAttributes> reader_attrs;
  if (FAILED(::MFCreateAttributes(reader_attrs.GetAddressOf(), 1))) {
    return Failure("export: MFCreateAttributes failed for the source reader.");
  }
  reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  ComPtr<IMFSourceReader> reader;
  HRESULT hr = ::MFCreateSourceReaderFromURL(request.source_video_path.c_str(),
                                             reader_attrs.Get(),
                                             reader.GetAddressOf());
  if (FAILED(hr) || reader == nullptr) {
    return Failure(Hr("export: MFCreateSourceReaderFromURL failed — the "
                      "recording may be missing or unreadable",
                      hr));
  }

  DWORD video_index = kNoStream;
  DWORD audio_index = kNoStream;
  IdentifyStreams(reader.Get(), &video_index, &audio_index);
  if (video_index == kNoStream) {
    return Failure("export: source has no decodable video stream.");
  }
  reader->SetStreamSelection(video_index, TRUE);

  // Force the video stream to BGRA (ARGB32 in MF terms). The reader
  // inserts a video processor to convert from NV12/etc.
  {
    ComPtr<IMFMediaType> rgb_type;
    if (FAILED(::MFCreateMediaType(rgb_type.GetAddressOf()))) {
      return Failure("export: MFCreateMediaType failed for the RGB32 output.");
    }
    rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    hr = reader->SetCurrentMediaType(video_index, nullptr, rgb_type.Get());
    if (FAILED(hr)) {
      return Failure(Hr("export: could not configure RGB32 video decode", hr));
    }
  }

  // Read the true source dimensions from the negotiated type rather than
  // trusting the project metadata.
  UINT32 source_w = 0;
  UINT32 source_h = 0;
  {
    ComPtr<IMFMediaType> current;
    if (FAILED(reader->GetCurrentMediaType(video_index, current.GetAddressOf())) ||
        FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &source_w,
                                    &source_h)) ||
        source_w == 0 || source_h == 0) {
      return Failure("export: could not determine source video dimensions.");
    }
  }

  // Total duration (HNS) for the progress fraction. Best-effort: some
  // containers don't report it, in which case progress stays indeterminate
  // (no per-frame fraction emitted) but a terminal 1.0 still fires on success.
  LONGLONG duration_hns = 0;
  {
    PROPVARIANT duration_var;
    PropVariantInit(&duration_var);
    if (SUCCEEDED(reader->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
            &duration_var)) &&
        duration_var.vt == VT_UI8) {
      duration_hns = static_cast<LONGLONG>(duration_var.uhVal.QuadPart);
    }
    PropVariantClear(&duration_var);
  }

  // Audio is optional. Try to pull it through as 48 kHz stereo int16 PCM;
  // if the source has no audio or the type is refused, fall back to a
  // video-only export rather than failing the whole render.
  // GIF has no audio track, so skip audio selection/decode entirely for it.
  bool has_audio = false;
  if (!gif && audio_index != kNoStream) {
    reader->SetStreamSelection(audio_index, TRUE);
    ComPtr<IMFMediaType> pcm_type;
    if (SUCCEEDED(::MFCreateMediaType(pcm_type.GetAddressOf()))) {
      pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
      pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
      if (SUCCEEDED(reader->SetCurrentMediaType(audio_index, nullptr,
                                                pcm_type.Get()))) {
        has_audio = true;
      } else {
        reader->SetStreamSelection(audio_index, FALSE);
      }
    }
  }

  // --- Slice 4 audio level: resolve the single gain/volume/normalize
  // multiplier applied to every decoded PCM sample. Normalize needs the
  // whole-track peak, so it runs a separate audio-only decode pass first
  // (matches macOS, which measures via its own reader). Loop-invariant.
  double audio_peak = 0.0;
  if (has_audio && request.auto_normalize) {
    audio_peak =
        MeasureSourceAudioPeak(request.source_video_path, request.is_cancelled);
  }
  const AudioGainStages audio_stages = ResolveAudioGainStages(
      request.audio_gain_db, request.audio_volume_percent,
      request.auto_normalize, request.target_loudness_dbfs, audio_peak);

  // --- Geometry: output size + source placement, via the tested helpers.
  const SizeF source_size{static_cast<double>(source_w),
                          static_cast<double>(source_h)};
  const PixelSize canvas =
      ToEvenPixelSize(ResolveTargetSize(source_size, request.layout,
                                        request.resolution));
  const RectF content = ComputeContentRect(
      SizeF{static_cast<double>(canvas.width),
            static_cast<double>(canvas.height)},
      source_size, ParseFitMode(request.fit), request.padding);

  // --- Direct2D device + context on the shared D3D11 device.
  ComPtr<ID2D1Factory1> d2d_factory;
  {
    D2D1_FACTORY_OPTIONS options{};
    hr = ::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                             __uuidof(ID2D1Factory1), &options,
                             reinterpret_cast<void**>(d2d_factory.GetAddressOf()));
    if (FAILED(hr) || d2d_factory == nullptr) {
      return Failure(Hr("export: D2D1CreateFactory failed", hr));
    }
  }
  ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(device.device()->QueryInterface(IID_PPV_ARGS(dxgi_device.GetAddressOf())))) {
    return Failure("export: ID3D11Device has no IDXGIDevice (BGRA support "
                   "flag missing?).");
  }
  ComPtr<ID2D1Device> d2d_device;
  if (FAILED(d2d_factory->CreateDevice(dxgi_device.Get(),
                                       d2d_device.GetAddressOf()))) {
    return Failure("export: ID2D1Factory1::CreateDevice failed.");
  }
  ComPtr<ID2D1DeviceContext> d2d_ctx;
  if (FAILED(d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                                             d2d_ctx.GetAddressOf()))) {
    return Failure("export: ID2D1Device::CreateDeviceContext failed.");
  }

  // Phase 8.2: optional cursor renderer. Draws the sidecar cursor on top of the
  // composited video each frame. Soft-fail at every step — a missing / malformed
  // sidecar or a geometry/brush failure simply renders no cursor; the export
  // never fails because of the cursor.
  std::unique_ptr<CursorExportRenderer> cursor_renderer;
  if (request.show_cursor && !request.cursor_sidecar_path.empty()) {
    cursor_renderer = CursorExportRenderer::Create(request.cursor_sidecar_path);
    if (cursor_renderer != nullptr &&
        !cursor_renderer->Prepare(d2d_factory.Get(), d2d_ctx.Get())) {
      cursor_renderer.reset();
    }
  }

  // Phase 8.3: optional smart-zoom controller. Builds auto-zoom segments from the
  // sidecar (clicks + cursor) and produces a smoothed per-frame transform. Same
  // soft-fail discipline as the cursor renderer — null → no zoom.
  std::unique_ptr<ZoomExportController> zoom_controller;
  if (request.zoom_enabled && !request.cursor_sidecar_path.empty()) {
    zoom_controller = ZoomExportController::Create(
        request.cursor_sidecar_path, duration_hns / 10000, request.zoom_factor);
  }

  // Phase 9.4: optional camera bubble. Opens camera/raw.mov on its own reader
  // and draws a masked bubble on top of the composite in canvas space (NOT under
  // the smart-zoom transform). Soft-fail: Create/Prepare returning null/false
  // simply renders no camera and the export proceeds screen-only. The bubble
  // rect is resolved once from the (loop-invariant) canvas + Dart geometry args.
  std::unique_ptr<CameraExportRenderer> camera_renderer;
  if (request.draw_camera && !request.camera_video_path.empty()) {
    camera_renderer = CameraExportRenderer::Create(
        request.camera_video_path, request.camera_start_offset_ms);
    if (camera_renderer != nullptr) {
      const CameraBubbleRect bubble = ComputeCameraBubbleRect(
          static_cast<double>(canvas.width), static_cast<double>(canvas.height),
          request.camera_has_center, request.camera_center_x,
          request.camera_center_y, request.camera_layout_preset,
          request.camera_size_factor);
      CameraExportRenderer::Style cam_style;
      cam_style.mirror = request.camera_mirror;
      cam_style.opacity = request.camera_opacity;
      cam_style.border_width = request.camera_border_width;
      cam_style.has_border_color = request.camera_border_color_argb.has_value();
      cam_style.border_argb = static_cast<std::uint32_t>(
          request.camera_border_color_argb.value_or(0));
      cam_style.shadow_preset = request.camera_shadow_preset;
      if (!camera_renderer->Prepare(d2d_factory.Get(), d2d_ctx.Get(), bubble,
                                    request.camera_shape,
                                    request.camera_corner_radius,
                                    request.camera_content_mode, cam_style)) {
        camera_renderer.reset();
      }
    }
  }

  // Reusable source bitmap: a fresh decoded frame is uploaded into it via
  // CopyFromMemory each iteration. Sized to the source; the fit/fill
  // scale happens in the DrawBitmap dest rect, not here.
  ComPtr<ID2D1Bitmap1> source_bitmap;
  {
    const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
    if (FAILED(d2d_ctx->CreateBitmap(D2D1::SizeU(source_w, source_h), nullptr,
                                     0, &props, source_bitmap.GetAddressOf()))) {
      return Failure("export: ID2D1DeviceContext::CreateBitmap failed for the "
                     "source frame.");
    }
  }

  // --- Output encoder at the target resolution. A .gif destination uses the
  // WIC GIF encoder (Slice 5B); otherwise the H.264 Sink Writer, whose
  // container (.mp4 vs .mov) is chosen by the destination_path extension and
  // whose bitrate comes from the Slice 5A preset (ignored by GIF, which is
  // palette-indexed). Both encoders are declared; only the selected one is
  // opened, and the lambdas below route every frame-loop call to it so the
  // loop stays single-path.
  clingfy::encoding::MfSinkWriterEncoder encoder;
  clingfy::encoding::GifEncoder gif_encoder;
  if (gif) {
    clingfy::encoding::EncoderConfig gif_config;
    gif_config.output_path = request.destination_path;
    gif_config.width = canvas.width;
    gif_config.height = canvas.height;
    if (auto err = gif_encoder.Open(gif_config, device)) {
      return Failure("export: GIF encoder open failed — " + err->message);
    }
  } else {
    clingfy::encoding::EncoderConfig enc_config;
    enc_config.output_path = request.destination_path;
    enc_config.width = canvas.width;
    enc_config.height = canvas.height;
    enc_config.fps = request.fps_hint != 0 ? request.fps_hint : 30u;
    enc_config.avg_bitrate_bps = ResolveVideoBitrateBps(
        request.bitrate, canvas.width, canvas.height, enc_config.fps);

    std::optional<clingfy::encoding::AudioEncoderConfig> audio_config;
    if (has_audio) {
      audio_config = clingfy::encoding::AudioEncoderConfig{};
    }
    if (auto err = encoder.Open(enc_config, device, audio_config)) {
      return Failure("export: encoder open failed — " + err->message);
    }
  }

  auto write_video_frame =
      [&](const clingfy::capture::CapturedVideoFrame& f)
      -> std::optional<clingfy::encoding::EncoderError> {
    return gif ? gif_encoder.WriteVideoFrame(f) : encoder.WriteVideoFrame(f);
  };
  auto cancel_encoder = [&]() {
    if (gif) {
      gif_encoder.Cancel();
    } else {
      encoder.Cancel();
    }
  };
  auto finalize_encoder =
      [&]() -> std::optional<clingfy::encoding::EncoderError> {
    return gif ? gif_encoder.Finalize() : encoder.Finalize();
  };

  // --- Frame loop: pull samples interleaved by timestamp.
  std::vector<BYTE> top_down;  // reused per video frame
  const D2D1_RECT_F dest_rect = D2D1::RectF(
      static_cast<float>(content.x), static_cast<float>(content.y),
      static_cast<float>(content.x + content.width),
      static_cast<float>(content.y + content.height));

  // --- Slice 3 canvas styling. All loop-invariant (it depends only on the
  // canvas / content rect / args, none of which change per frame), so the
  // color, clamped radius, and the rounded-clip geometry + layer are
  // resolved/built once here.
  const RgbaColor bg = ResolveBackgroundColor(request.background_color);
  // GIF has no partial alpha, and the composited texture is premultiplied —
  // feeding a translucent background through the WIC straight-alpha path would
  // darken padding margins / anti-aliased corners. Force the GIF background
  // fully opaque so those regions show the solid background color instead.
  const D2D1_COLOR_F clear_color =
      D2D1::ColorF(static_cast<float>(bg.r), static_cast<float>(bg.g),
                   static_cast<float>(bg.b),
                   gif ? 1.0f : static_cast<float>(bg.a));
  const double corner_radius_px =
      ResolveCornerRadiusPx(request.corner_radius, content);
  ComPtr<ID2D1RoundedRectangleGeometry> rounded_clip;
  ComPtr<ID2D1Layer> rounded_layer;
  if (corner_radius_px > 0.0) {
    // Best-effort: if the geometry or layer can't be created, fall back to
    // square corners rather than failing the whole export.
    if (FAILED(d2d_factory->CreateRoundedRectangleGeometry(
            D2D1::RoundedRect(dest_rect,
                              static_cast<float>(corner_radius_px),
                              static_cast<float>(corner_radius_px)),
            rounded_clip.GetAddressOf())) ||
        FAILED(d2d_ctx->CreateLayer(nullptr, rounded_layer.GetAddressOf()))) {
      rounded_clip.Reset();
      rounded_layer.Reset();
    }
  }

  std::uint64_t video_frames = 0;
  std::uint64_t audio_packets = 0;
  // Phase 8.2: rebase cursor lookups to the first decoded video frame, so the
  // sidecar's recording-relative tMs lines up with the file's PTS regardless of
  // the container's absolute PTS base.
  std::int64_t first_video_hns = -1;
  // Phase 8.3: previous KEPT video frame's PTS, for the smoother's dt.
  std::int64_t prev_frame_hns = -1;
  bool video_eos = false;
  bool audio_eos = !has_audio;  // nothing to drain when there is no audio
  double last_progress_emitted = -1.0;  // Slice 5A: throttle progress ticks

  // Slice 5B GIF decimation: a running emit target on an ideal grid (see
  // gif_export_policy.h). Seeded so the first decoded frame is always kept; a
  // 30/60 fps source becomes a ~kGifTargetFps GIF, jitter-tolerant.
  std::int64_t gif_emit_target_hns = kGifEmitTargetStart;

  // Slice 5A: emit a 0..1 progress fraction from the video PTS, throttled to
  // ~1% steps so a long clip doesn't flood the channel. Indeterminate (no emit)
  // when the source reported no duration. Shared by the kept- and (GIF-)dropped-
  // frame paths so the bar advances per decoded frame regardless of decimation.
  auto emit_progress = [&](LONGLONG ts) {
    if (request.on_progress && duration_hns > 0) {
      double frac =
          static_cast<double>(ts) / static_cast<double>(duration_hns);
      frac = frac < 0.0 ? 0.0 : (frac > 1.0 ? 1.0 : frac);
      if (frac >= last_progress_emitted + 0.01) {
        last_progress_emitted = frac;
        request.on_progress(frac);
      }
    }
  };

  while (!(video_eos && audio_eos)) {
    // Slice 5A: cancel between samples — release the writer without
    // finalizing and delete the partial file, then reply cleanly.
    if (request.is_cancelled && request.is_cancelled()) {
      cancel_encoder();
      return Cancelled(request.destination_path);
    }
    DWORD actual_index = 0;
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0,
                            &actual_index, &flags, &timestamp,
                            sample.GetAddressOf());
    if (FAILED(hr)) {
      cancel_encoder();
      return Failure(Hr("export: IMFSourceReader::ReadSample failed", hr));
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      if (actual_index == video_index) {
        video_eos = true;
      } else if (actual_index == audio_index) {
        audio_eos = true;
      }
    }
    if (sample == nullptr) {
      continue;
    }

    if (actual_index == video_index) {
      // Anchor the cursor-time rebase to the first decoded video frame (before
      // any GIF decimation) so it tracks the true start of the timeline.
      if (first_video_hns < 0) {
        first_video_hns = timestamp;
      }
      // Slice 5B: drop frames that fall inside the target GIF interval before
      // any composite/encode work; still advance progress for the dropped
      // frame so the bar tracks decode position. Non-GIF keeps every frame.
      if (gif && !ShouldKeepGifFrame(timestamp, gif_emit_target_hns)) {
        emit_progress(timestamp);
        continue;
      }
      if (!ExtractTopDownBgra(sample.Get(), source_w, source_h, &top_down)) {
        cancel_encoder();
        return Failure("export: failed to read a decoded video frame buffer.");
      }
      if (FAILED(source_bitmap->CopyFromMemory(nullptr, top_down.data(),
                                               source_w * 4u))) {
        cancel_encoder();
        return Failure("export: ID2D1Bitmap::CopyFromMemory failed.");
      }

      // Phase 9.4: advance the camera's held frame BEFORE BeginDraw (the upload
      // is a CopyFromMemory, kept outside the draw like the screen frame above).
      // frame_ms is recording-relative, rebased to the first decoded frame.
      if (camera_renderer != nullptr) {
        const std::int64_t cam_frame_ms =
            first_video_hns >= 0 ? (timestamp - first_video_hns) / 10000 : 0;
        camera_renderer->Advance(cam_frame_ms);
      }

      // Fresh output texture per frame: the encoder MFT may hold the
      // previous frame's surface asynchronously, so reuse would risk
      // overwriting a frame still in flight.
      D3D11_TEXTURE2D_DESC desc{};
      desc.Width = canvas.width;
      desc.Height = canvas.height;
      desc.MipLevels = 1;
      desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_DEFAULT;
      desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      ComPtr<ID3D11Texture2D> out_texture;
      if (FAILED(device.device()->CreateTexture2D(&desc, nullptr,
                                                  out_texture.GetAddressOf()))) {
        cancel_encoder();
        return Failure("export: CreateTexture2D failed for an output frame.");
      }
      ComPtr<IDXGISurface> out_surface;
      if (FAILED(out_texture.As(&out_surface))) {
        cancel_encoder();
        return Failure("export: output texture has no IDXGISurface.");
      }
      const D2D1_BITMAP_PROPERTIES1 target_props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_TARGET,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_PREMULTIPLIED));
      ComPtr<ID2D1Bitmap1> target_bitmap;
      if (FAILED(d2d_ctx->CreateBitmapFromDxgiSurface(
              out_surface.Get(), &target_props, target_bitmap.GetAddressOf()))) {
        cancel_encoder();
        return Failure("export: CreateBitmapFromDxgiSurface failed.");
      }

      d2d_ctx->SetTarget(target_bitmap.Get());
      d2d_ctx->BeginDraw();
      // Background first (fills the whole canvas, including padding margins
      // and letterbox bars), then the video on top — clipped to a rounded
      // rect so the corners reveal the background, matching the macOS
      // bg-fill-then-rounded-video draw order.
      d2d_ctx->Clear(clear_color);

      // The frame's recording-relative ms (rebased to the first decoded frame),
      // shared by the cursor lookup and the zoom controller.
      const std::int64_t frame_ms =
          first_video_hns >= 0 ? (timestamp - first_video_hns) / 10000 : 0;

      // Phase 8.3: advance the smart-zoom transform for this frame. The cursor
      // (8.2) is drawn UNDER the same transform, so the cursor and the magnified
      // video share one coordinate space.
      ZoomExportController::Frame zf;
      if (zoom_controller != nullptr) {
        const double dt_seconds =
            prev_frame_hns >= 0
                ? static_cast<double>(timestamp - prev_frame_hns) / 10'000'000.0
                : 1.0 / static_cast<double>(
                            request.fps_hint != 0 ? request.fps_hint : 30u);
        zf = zoom_controller->Advance(frame_ms, dt_seconds);
      }
      prev_frame_hns = timestamp;
      const bool zooming = zf.active && zf.zoom > 1.0;

      // Content clip: rounded layer when a corner radius is set, else an
      // axis-aligned clip to the content rect when drawing a cursor or a zoom (so
      // neither bleeds into the padding/background). No clip otherwise — the
      // plain composition path stays byte-identical to before.
      bool pushed_layer = false;
      bool pushed_clip = false;
      if (rounded_clip != nullptr) {
        d2d_ctx->PushLayer(
            D2D1::LayerParameters1(D2D1::InfiniteRect(), rounded_clip.Get(),
                                   D2D1_ANTIALIAS_MODE_PER_PRIMITIVE),
            rounded_layer.Get());
        pushed_layer = true;
      } else if (zooming || cursor_renderer != nullptr) {
        d2d_ctx->PushAxisAlignedClip(dest_rect, D2D1_ANTIALIAS_MODE_ALIASED);
        pushed_clip = true;
      }

      // Apply the zoom transform (identity when not zooming). The clip above was
      // pushed under the identity transform, so it stays in canvas space while
      // the content below is magnified about the (clamped) focus center.
      if (zooming) {
        const double cw = content.width;
        const double ch = content.height;
        const double half = 0.5 / zf.zoom;
        const double window_left = (zf.center_x - half) * cw;
        const double window_top = (zf.center_y - half) * ch;
        const D2D1_MATRIX_3X2_F zoom_m =
            D2D1::Matrix3x2F::Translation(
                -(static_cast<float>(content.x + window_left)),
                -(static_cast<float>(content.y + window_top))) *
            D2D1::Matrix3x2F::Scale(static_cast<float>(zf.zoom),
                                    static_cast<float>(zf.zoom)) *
            D2D1::Matrix3x2F::Translation(static_cast<float>(content.x),
                                          static_cast<float>(content.y));
        d2d_ctx->SetTransform(zoom_m);
      }

      d2d_ctx->DrawBitmap(source_bitmap.Get(), dest_rect, 1.0f,
                          D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
      if (cursor_renderer != nullptr) {
        cursor_renderer->Draw(d2d_ctx.Get(), frame_ms, dest_rect,
                              static_cast<double>(source_w),
                              static_cast<double>(source_h),
                              request.cursor_size);
        // Phase 8.4: click ripples, drawn under the same transform so they stay
        // aligned with the cursor + smart zoom.
        cursor_renderer->DrawClicks(d2d_ctx.Get(), frame_ms, dest_rect,
                                    static_cast<double>(source_w),
                                    static_cast<double>(source_h));
      }
      if (zooming) {
        d2d_ctx->SetTransform(D2D1::Matrix3x2F::Identity());
      }
      if (pushed_layer) {
        d2d_ctx->PopLayer();
      } else if (pushed_clip) {
        d2d_ctx->PopAxisAlignedClip();
      }
      // Phase 9.4: the camera bubble draws LAST, in canvas space with an
      // identity transform (the zoom transform was reset above and the content
      // clip/layer popped), so it sits on top of the screen + cursor + clicks
      // and is NOT magnified by smart zoom. Its own mask clips the bubble.
      if (camera_renderer != nullptr) {
        camera_renderer->Draw(d2d_ctx.Get());
      }
      const HRESULT end_hr = d2d_ctx->EndDraw();
      d2d_ctx->SetTarget(nullptr);
      if (FAILED(end_hr)) {
        cancel_encoder();
        return Failure(Hr("export: Direct2D EndDraw failed", end_hr));
      }
      // Flush so the composite completes before the encoder MFT reads the
      // texture on its own thread.
      device.context()->Flush();

      clingfy::capture::CapturedVideoFrame frame;
      frame.texture = out_texture;
      frame.width = canvas.width;
      frame.height = canvas.height;
      frame.timestamp_hns = timestamp;
      if (auto err = write_video_frame(frame)) {
        cancel_encoder();
        return Failure("export: encoder WriteVideoFrame failed — " +
                       err->message);
      }
      ++video_frames;
      if (gif) {
        gif_emit_target_hns = AdvanceGifEmitTarget(gif_emit_target_hns, timestamp);
      }
      emit_progress(timestamp);
    } else if (has_audio && actual_index == audio_index) {
      ComPtr<IMFMediaBuffer> audio_buffer;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(
              audio_buffer.GetAddressOf())) &&
          audio_buffer != nullptr) {
        BYTE* data = nullptr;
        DWORD max_len = 0;
        DWORD cur_len = 0;
        if (SUCCEEDED(audio_buffer->Lock(&data, &max_len, &cur_len)) &&
            data != nullptr && cur_len > 0) {
          const std::uint32_t int16_count =
              cur_len / static_cast<std::uint32_t>(sizeof(std::int16_t));
          clingfy::audio::MixedPacket packet;
          packet.samples.resize(int16_count);
          std::memcpy(packet.samples.data(), data,
                      static_cast<size_t>(int16_count) * sizeof(std::int16_t));
          packet.frame_count = int16_count / 2u;  // stereo interleaved
          packet.timestamp_hns = timestamp;
          audio_buffer->Unlock();
          // Slice 4: scale the decoded PCM by the resolved gain/volume/
          // normalize stages (a no-op when both are 1.0). Touches sample
          // values only — never frame_count or timestamp, so A/V sync holds.
          ApplyAudioGain(packet.samples.data(), packet.samples.size(),
                         audio_stages);
          if (auto err = encoder.WriteAudioPacket(packet)) {
            cancel_encoder();
            return Failure("export: encoder WriteAudioPacket failed — " +
                           err->message);
          }
          ++audio_packets;
        } else if (data != nullptr) {
          audio_buffer->Unlock();
        }
      }
    }
  }

  if (video_frames == 0) {
    cancel_encoder();
    return Failure("export: no video frames were decoded from the source.");
  }

  if (auto err = finalize_encoder()) {
    return Failure("export: encoder finalize failed — " + err->message);
  }

  // Slice 5A: terminal 1.0 so the UI lands exactly at 100% (matches macOS,
  // which emits the upper bound on completion).
  if (request.on_progress) {
    request.on_progress(1.0);
  }

  RenderResult out;
  out.ok = true;
  out.output_width = canvas.width;
  out.output_height = canvas.height;
  out.video_frames_written = video_frames;
  out.audio_packets_written = audio_packets;
  out.had_audio = has_audio;
  return out;
}

}  // namespace clingfy::capture::export_
