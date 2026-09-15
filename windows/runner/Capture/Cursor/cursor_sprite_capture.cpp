#include "Capture/Cursor/cursor_sprite_capture.h"

#include <algorithm>

namespace clingfy::capture {

namespace {

// Pull a bitmap's pixels as top-down 32-bit BGRA.
bool ReadBitmapBgra(HDC dc, HBITMAP bitmap, int width, int height,
                    std::vector<std::uint8_t>* out) {
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  // NEGATIVE height requests top-down rows. GDI's default is bottom-up, which
  // would deliver every cursor vertically mirrored.
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  out->assign(static_cast<size_t>(width) * height * 4, 0);
  return ::GetDIBits(dc, bitmap, 0, static_cast<UINT>(height), out->data(),
                     &info, DIB_RGB_COLORS) != 0;
}

// True when every alpha byte is zero. A colour cursor's mask is sometimes the
// only thing carrying transparency, and some drivers hand back a colour bitmap
// with an all-zero alpha channel; treating that as "fully transparent" would
// erase the cursor entirely, so it means "fall back to the AND mask" instead.
bool AlphaIsAllZero(const std::vector<std::uint8_t>& bgra) {
  for (size_t i = 3; i < bgra.size(); i += 4) {
    if (bgra[i] != 0) {
      return false;
    }
  }
  return true;
}

}  // namespace

bool RasterizeCursor(HCURSOR cursor, CursorSprite* out) {
  if (cursor == nullptr || out == nullptr) {
    return false;
  }
  ICONINFO info{};
  if (::GetIconInfo(cursor, &info) == 0) {
    return false;
  }
  // GetIconInfo hands over ownership of both bitmaps; leaking them 60 times a
  // second would exhaust GDI handles within minutes.
  struct BitmapGuard {
    HBITMAP mask = nullptr;
    HBITMAP color = nullptr;
    ~BitmapGuard() {
      if (mask != nullptr) ::DeleteObject(mask);
      if (color != nullptr) ::DeleteObject(color);
    }
  } guard{info.hbmMask, info.hbmColor};

  BITMAP mask_bm{};
  if (::GetObjectW(info.hbmMask, sizeof(mask_bm), &mask_bm) == 0) {
    return false;
  }

  HDC screen = ::GetDC(nullptr);
  if (screen == nullptr) {
    return false;
  }
  struct DcGuard {
    HDC dc;
    ~DcGuard() {
      if (dc != nullptr) ::ReleaseDC(nullptr, dc);
    }
  } dc_guard{screen};

  const int width = mask_bm.bmWidth;
  // A MONOCHROME cursor stacks its AND mask above its XOR mask in one bitmap
  // of double height; a colour cursor's mask is a single plane.
  const bool monochrome = info.hbmColor == nullptr;
  const int height = monochrome ? mask_bm.bmHeight / 2 : mask_bm.bmHeight;
  if (width <= 0 || height <= 0) {
    return false;
  }

  std::vector<std::uint8_t> mask_bits;
  if (!ReadBitmapBgra(screen, info.hbmMask, width,
                      monochrome ? height * 2 : height, &mask_bits)) {
    return false;
  }

  out->width = width;
  out->height = height;
  out->hotspot_x = static_cast<std::int32_t>(info.xHotspot);
  out->hotspot_y = static_cast<std::int32_t>(info.yHotspot);
  out->pixels.assign(static_cast<size_t>(width) * height * 4, 0);

  const size_t plane = static_cast<size_t>(width) * height * 4;

  if (monochrome) {
    // AND=1, XOR=0 -> transparent.  AND=1, XOR=1 -> INVERT the screen; there
    // is no screen to sample here, so render it opaque white, which is what
    // the classic I-beam and resize cursors want on typical content.
    // AND=0, XOR=0 -> opaque black.  AND=0, XOR=1 -> opaque white.
    for (size_t i = 0; i < static_cast<size_t>(width) * height; ++i) {
      const bool and_bit = mask_bits[i * 4] != 0;          // upper plane
      const bool xor_bit = mask_bits[plane + i * 4] != 0;  // lower plane
      std::uint8_t v = 0;
      std::uint8_t a = 255;
      if (and_bit && !xor_bit) {
        a = 0;  // transparent
      } else if (and_bit && xor_bit) {
        v = 255;  // invert -> white
      } else {
        v = xor_bit ? 255 : 0;
      }
      // Premultiplied: a transparent pixel must carry zero colour too, or
      // Direct2D blends a black fringe around the whole glyph.
      const std::uint8_t c = a == 0 ? 0 : v;
      out->pixels[i * 4 + 0] = c;
      out->pixels[i * 4 + 1] = c;
      out->pixels[i * 4 + 2] = c;
      out->pixels[i * 4 + 3] = a;
    }
    return true;
  }

  std::vector<std::uint8_t> color_bits;
  if (!ReadBitmapBgra(screen, info.hbmColor, width, height, &color_bits)) {
    return false;
  }
  const bool use_mask_alpha = AlphaIsAllZero(color_bits);
  for (size_t i = 0; i < static_cast<size_t>(width) * height; ++i) {
    std::uint8_t a = color_bits[i * 4 + 3];
    if (use_mask_alpha) {
      // The AND mask is 1 where the cursor is TRANSPARENT.
      a = mask_bits[i * 4] != 0 ? 0 : 255;
    }
    // Premultiply. GDI hands back straight alpha; handing that to Direct2D as
    // premultiplied makes every semi-transparent edge too bright.
    const auto premul = [a](std::uint8_t c) {
      return static_cast<std::uint8_t>((static_cast<int>(c) * a + 127) / 255);
    };
    out->pixels[i * 4 + 0] = premul(color_bits[i * 4 + 0]);
    out->pixels[i * 4 + 1] = premul(color_bits[i * 4 + 1]);
    out->pixels[i * 4 + 2] = premul(color_bits[i * 4 + 2]);
    out->pixels[i * 4 + 3] = a;
  }
  return true;
}

int CursorSpriteCache::IdFor(HCURSOR cursor, bool* is_new,
                             CursorSprite* out_sprite) {
  if (is_new != nullptr) {
    *is_new = false;
  }
  if (cursor == nullptr) {
    return -1;
  }
  if (const auto hit = by_handle_.find(cursor); hit != by_handle_.end()) {
    return hit->second;
  }
  if (failed_.count(cursor) > 0) {
    return -1;  // already known-bad; do not retry every tick
  }
  CursorSprite sprite;
  if (!RasterizeCursor(cursor, &sprite)) {
    failed_[cursor] = true;
    return -1;
  }
  sprite.id = next_id_++;
  by_handle_[cursor] = sprite.id;
  if (is_new != nullptr) {
    *is_new = true;
  }
  if (out_sprite != nullptr) {
    *out_sprite = std::move(sprite);
  }
  return by_handle_[cursor];
}

}  // namespace clingfy::capture
