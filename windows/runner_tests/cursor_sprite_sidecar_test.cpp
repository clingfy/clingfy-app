#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "Capture/Cursor/cursor_base64.h"
#include "Capture/Cursor/cursor_sidecar_reader.h"

// Cursor SHAPE capture, on the parts that can be tested without a live cursor.
//
// The rasterizer itself needs real GDI handles, so what is pinned here is
// everything a shape has to survive on its way to the export: the codec that
// carries the pixels, the schema that carries the ids, and the rule that an
// older recording still renders.
namespace clingfy::capture {
namespace {

std::string Header() {
  return R"({"type":"header","schemaVersion":2,"targetType":"display",)"
         R"("width":1920,"height":1080})" "\n";
}

// A 2x1 sprite: opaque blue pixel, then a transparent one.
std::vector<std::uint8_t> TinyPixels() {
  return {255, 0, 0, 255, 0, 0, 0, 0};
}

// --- base64 -----------------------------------------------------------------

TEST(CursorBase64Test, RoundTripsArbitraryBytes) {
  // Every byte value, so a sign-extension bug on the 0x80-0xFF half shows up.
  std::vector<std::uint8_t> bytes(256);
  for (int i = 0; i < 256; ++i) {
    bytes[static_cast<size_t>(i)] = static_cast<std::uint8_t>(i);
  }
  EXPECT_EQ(Base64Decode(Base64Encode(bytes)), bytes);
}

TEST(CursorBase64Test, HandlesEveryPaddingCase) {
  // Lengths mod 3 of 0, 1 and 2 take three different tail paths, and getting
  // the padding wrong truncates the last pixel of a sprite.
  for (size_t n = 0; n <= 6; ++n) {
    std::vector<std::uint8_t> bytes(n, 0xAB);
    for (size_t i = 0; i < n; ++i) {
      bytes[i] = static_cast<std::uint8_t>(i * 37 + 1);
    }
    const std::string encoded = Base64Encode(bytes);
    EXPECT_EQ(encoded.size() % 4, 0u) << "length " << n << " is not padded";
    EXPECT_EQ(Base64Decode(encoded), bytes) << "length " << n;
  }
}

TEST(CursorBase64Test, EncodesToTheKnownAnswer) {
  // Pinned against a literal so a self-consistent but WRONG alphabet cannot
  // pass by round-tripping with itself.
  const std::vector<std::uint8_t> bytes{'M', 'a', 'n'};
  EXPECT_EQ(Base64Encode(bytes), "TWFu");
  const std::vector<std::uint8_t> one{'M'};
  EXPECT_EQ(Base64Encode(one), "TQ==");
}

TEST(CursorBase64Test, EmptyIsEmpty) {
  EXPECT_TRUE(Base64Encode({}).empty());
  EXPECT_TRUE(Base64Decode("").empty());
}

// --- the sidecar schema -----------------------------------------------------

TEST(CursorSpriteSidecarTest, ParsesASpriteAndItsReferencingSample) {
  const std::string jsonl =
      Header() +
      R"({"type":"sprite","id":0,"width":2,"height":1,"hotspotX":1,)"
      R"("hotspotY":0,"pixels":")" + Base64Encode(TinyPixels()) + R"("})" "\n"
      R"({"type":"sample","tMs":0,"screenX":5,"screenY":6,"x":5,"y":6,)"
      R"("visible":true,"spriteId":0})" "\n";

  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  ASSERT_EQ(data->sprites.size(), 1u);
  EXPECT_EQ(data->sprites[0].id, 0);
  EXPECT_EQ(data->sprites[0].width, 2);
  EXPECT_EQ(data->sprites[0].height, 1);
  EXPECT_EQ(data->sprites[0].hotspot_x, 1);
  EXPECT_EQ(data->sprites[0].pixels, TinyPixels());
  ASSERT_EQ(data->samples.size(), 1u);
  EXPECT_EQ(data->samples[0].sprite_id, 0);
}

TEST(CursorSpriteSidecarTest, AV1FileStillParsesAndAsksForTheArrow) {
  // THE backward-compatibility guarantee. Shapes are record-time-only, so every
  // recording made before this feature has none — and must keep exporting.
  const std::string jsonl =
      Header() +
      R"({"type":"sample","tMs":0,"screenX":1,"screenY":2,"x":1,"y":2,)"
      R"("visible":true})" "\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  EXPECT_TRUE(data->sprites.empty());
  ASSERT_EQ(data->samples.size(), 1u);
  EXPECT_EQ(data->samples[0].sprite_id, -1) << "should fall back to the arrow";
}

TEST(CursorSpriteSidecarTest, ASpriteWhosePayloadDoesNotMatchItsSizeIsDropped) {
  // Guards a buffer over-read: the renderer hands `pixels.data()` to Direct2D
  // with a stride derived from `width`, so a short payload would read past the
  // end of the vector.
  const std::string jsonl =
      Header() +
      R"({"type":"sprite","id":0,"width":64,"height":64,"hotspotX":0,)"
      R"("hotspotY":0,"pixels":"AAAA"})" "\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  EXPECT_TRUE(data->sprites.empty());
}

TEST(CursorSpriteSidecarTest, AMalformedSpriteLineDoesNotKillTheParse) {
  const std::string jsonl =
      Header() +
      R"({"type":"sprite","id":0,"width":2})" "\n" +
      R"({"type":"sample","tMs":7,"screenX":1,"screenY":2,"x":1,"y":2,)"
      R"("visible":true})" "\n";
  const auto data = ParseCursorSidecar(jsonl);
  ASSERT_TRUE(data.has_value());
  EXPECT_TRUE(data->sprites.empty());
  EXPECT_EQ(data->samples.size(), 1u) << "the sample after it must survive";
}

// --- shape selection over time ----------------------------------------------

TEST(CursorSpriteSidecarTest, TheShapeDoesNotInterpolateBetweenSamples) {
  // Position interpolates for smooth motion; a SHAPE cannot — there is no
  // halfway between an arrow and an I-beam. Between two samples the one
  // already on screen must stay until the next sample's time is reached, or
  // the cursor would visibly change shape early.
  std::vector<CursorSidecarSample> samples(2);
  samples[0] = {0, 0, 0, true, 3};
  samples[1] = {100, 100, 0, true, 7};

  const auto early = SampleCursorAt(samples, 10);
  EXPECT_EQ(early.sprite_id, 3);
  const auto late = SampleCursorAt(samples, 99);
  EXPECT_EQ(late.sprite_id, 3) << "switched to the next shape early";
  const auto at_next = SampleCursorAt(samples, 100);
  EXPECT_EQ(at_next.sprite_id, 7);
  // Position still interpolates — the shape rule must not have frozen it.
  EXPECT_GT(late.x, early.x);
}

TEST(CursorSpriteSidecarTest, ClampingPastTheEndsKeepsTheirShapes) {
  std::vector<CursorSidecarSample> samples(2);
  samples[0] = {10, 0, 0, true, 1};
  samples[1] = {20, 5, 5, true, 2};
  EXPECT_EQ(SampleCursorAt(samples, 0).sprite_id, 1);
  EXPECT_EQ(SampleCursorAt(samples, 9999).sprite_id, 2);
}

}  // namespace
}  // namespace clingfy::capture
