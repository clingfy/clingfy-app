#include "Capture/Camera/camera_preview_support.h"

#include <algorithm>

namespace clingfy::capture {

namespace {

std::uint8_t ClampByte(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return static_cast<std::uint8_t>(v);
}

}  // namespace

PreviewSize ComputePreviewSize(int src_w, int src_h, int max_dim) {
  if (src_w <= 0 || src_h <= 0 || max_dim <= 0) {
    return PreviewSize{0, 0};
  }
  const int longest = std::max(src_w, src_h);
  if (longest <= max_dim) {
    return PreviewSize{std::max(2, src_w), std::max(2, src_h)};
  }
  const double scale = static_cast<double>(max_dim) / static_cast<double>(longest);
  const int w = std::max(2, static_cast<int>(src_w * scale + 0.5));
  const int h = std::max(2, static_cast<int>(src_h * scale + 0.5));
  return PreviewSize{w, h};
}

bool ConvertToBgra(CameraPixelFormat format, const std::uint8_t* src, int src_w,
                   int src_h, int src_stride, std::uint8_t* dst_bgra, int dst_w,
                   int dst_h) {
  if (src == nullptr || dst_bgra == nullptr || src_w <= 0 || src_h <= 0 ||
      dst_w <= 0 || dst_h <= 0 || src_stride <= 0) {
    return false;
  }

  if (format == CameraPixelFormat::kBgra32) {
    for (int dy = 0; dy < dst_h; ++dy) {
      const int sy = std::min(src_h - 1, dy * src_h / dst_h);
      const std::uint8_t* src_row = src + static_cast<size_t>(sy) * src_stride;
      std::uint8_t* dst_row = dst_bgra + static_cast<size_t>(dy) * dst_w * 4;
      for (int dx = 0; dx < dst_w; ++dx) {
        const int sx = std::min(src_w - 1, dx * src_w / dst_w);
        const std::uint8_t* sp = src_row + static_cast<size_t>(sx) * 4;
        std::uint8_t* dp = dst_row + static_cast<size_t>(dx) * 4;
        dp[0] = sp[0];
        dp[1] = sp[1];
        dp[2] = sp[2];
        dp[3] = 255;
      }
    }
    return true;
  }

  // NV12: Y plane (src_stride * src_h), then interleaved U,V at half res.
  const std::uint8_t* y_plane = src;
  const std::uint8_t* uv_plane = src + static_cast<size_t>(src_stride) * src_h;
  for (int dy = 0; dy < dst_h; ++dy) {
    const int sy = std::min(src_h - 1, dy * src_h / dst_h);
    std::uint8_t* dst_row = dst_bgra + static_cast<size_t>(dy) * dst_w * 4;
    for (int dx = 0; dx < dst_w; ++dx) {
      const int sx = std::min(src_w - 1, dx * src_w / dst_w);
      const int y = y_plane[static_cast<size_t>(sy) * src_stride + sx];
      const int uv_row = sy / 2;
      const int uv_col = (sx / 2) * 2;
      // Clamp the V column to the row so an odd width with a tight stride cannot
      // read one byte past the UV plane (the recorder always passes even dims,
      // but this keeps the public helper safe for any caller).
      const int uv_col_v = std::min(uv_col + 1, src_stride - 1);
      const int u =
          uv_plane[static_cast<size_t>(uv_row) * src_stride + uv_col];
      const int v =
          uv_plane[static_cast<size_t>(uv_row) * src_stride + uv_col_v];
      // BT.601 limited-range YUV -> RGB.
      const int c = y - 16;
      const int d = u - 128;
      const int e = v - 128;
      const int r = (298 * c + 409 * e + 128) >> 8;
      const int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
      const int b = (298 * c + 516 * d + 128) >> 8;
      std::uint8_t* dp = dst_row + static_cast<size_t>(dx) * 4;
      dp[0] = ClampByte(b);
      dp[1] = ClampByte(g);
      dp[2] = ClampByte(r);
      dp[3] = 255;
    }
  }
  return true;
}

}  // namespace clingfy::capture
