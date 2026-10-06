#include "Capture/Export/export_format.h"

#include <gtest/gtest.h>

#include <cstdint>

namespace clingfy::capture::export_ {
namespace {

// ---- ResolveExportExtension -------------------------------------------------

TEST(ResolveExportExtensionTest, Mp4IsMp4) {
  EXPECT_EQ(ResolveExportExtension("mp4"), ".mp4");
  EXPECT_EQ(ResolveExportExtension("MP4"), ".mp4");  // case-insensitive
}

TEST(ResolveExportExtensionTest, MovEmptyAndUnknownAreMov) {
  EXPECT_EQ(ResolveExportExtension("mov"), ".mov");
  EXPECT_EQ(ResolveExportExtension(""), ".mov");
  EXPECT_EQ(ResolveExportExtension("wat"), ".mov");
}

TEST(ResolveExportExtensionTest, GifIsGif) {
  // Slice 5B: gif is a real animated GIF now, not a .mov fallback.
  EXPECT_EQ(ResolveExportExtension("gif"), ".gif");
  EXPECT_EQ(ResolveExportExtension("GIF"), ".gif");  // case-insensitive
}

// ---- FormatWasDowngraded ----------------------------------------------------

TEST(FormatWasDowngradedTest, NothingIsDowngradedNow) {
  // Windows emits .mov / .mp4 / .gif natively (Slices 5A/5B) — no format is
  // silently written in a different container.
  EXPECT_FALSE(FormatWasDowngraded("mp4"));
  EXPECT_FALSE(FormatWasDowngraded("mov"));
  EXPECT_FALSE(FormatWasDowngraded(""));
  EXPECT_FALSE(FormatWasDowngraded("gif"));
  EXPECT_FALSE(FormatWasDowngraded("GIF"));
}

// ---- ResolveVideoBitrateBps -------------------------------------------------

// ---- ResolveAudioBitrateBps -------------------------------------------------

TEST(ResolveAudioBitrateBpsTest, StandardIsOneNinetyTwoKbpsMatchingMacOS) {
  // The parity fix. The struct default was 128 kbps while macOS has always
  // exported 192 kbps for the same project, and nothing documented the gap.
  EXPECT_EQ(ResolveAudioBitrateBps("standard"), 192'000u);
}

TEST(ResolveAudioBitrateBpsTest, AnEmptyOrUnknownTierIsStandard) {
  // ReadString has no fallback parameter, so an absent `audioQuality` key
  // arrives as the empty string. That must mean "standard", not zero.
  EXPECT_EQ(ResolveAudioBitrateBps(""), 192'000u);
  EXPECT_EQ(ResolveAudioBitrateBps("ultra"), 192'000u);
  EXPECT_EQ(ResolveAudioBitrateBps("auto"), 192'000u);
}

TEST(ResolveAudioBitrateBpsTest, IsCaseInsensitiveLikeTheOtherResolvers) {
  EXPECT_EQ(ResolveAudioBitrateBps("HIGH"), ResolveAudioBitrateBps("high"));
  EXPECT_EQ(ResolveAudioBitrateBps("Best"), ResolveAudioBitrateBps("best"));
}

TEST(ResolveAudioBitrateBpsTest, UpperTiersClampUntilTheMftMatrixIsProbed) {
  // Deliberate, and the reason the audio-quality control is macOS-only: the
  // Media Foundation AAC encoder's accepted (rate, channels, bitrate) matrix
  // has not been measured on Windows hardware, and it refuses late with an
  // opaque HRESULT from AddStream. macOS measured its own ceiling (320 kbps
  // accepted at 48 kHz stereo, 384 refused) and offers the full ladder.
  //
  // When somebody probes the MFT, raise kAudioBitrateCeilingBps and change
  // the expectation here — that is the whole change.
  EXPECT_EQ(ResolveAudioBitrateBps("high"), 192'000u);
  EXPECT_EQ(ResolveAudioBitrateBps("best"), 192'000u);
}

TEST(ResolveAudioBitrateBpsTest, EveryTierIsDivisibleByEight) {
  // MF_MT_AUDIO_AVG_BYTES_PER_SECOND is set as bps / 8 with integer
  // arithmetic, so a remainder is silently truncated.
  for (const char* tier : {"standard", "high", "best", ""}) {
    EXPECT_EQ(ResolveAudioBitrateBps(tier) % 8u, 0u) << "tier: " << tier;
  }
}

TEST(ResolveVideoBitrateBpsTest, PresetsAreOrderedLowMedHigh) {
  const std::uint32_t low = ResolveVideoBitrateBps("low", 1920, 1080, 30);
  const std::uint32_t med = ResolveVideoBitrateBps("medium", 1920, 1080, 30);
  const std::uint32_t high = ResolveVideoBitrateBps("high", 1920, 1080, 30);
  EXPECT_LT(low, med);
  EXPECT_LT(med, high);
}

TEST(ResolveVideoBitrateBpsTest, AutoAndUnknownMatchMedium) {
  const std::uint32_t med = ResolveVideoBitrateBps("medium", 1920, 1080, 30);
  EXPECT_EQ(ResolveVideoBitrateBps("auto", 1920, 1080, 30), med);
  EXPECT_EQ(ResolveVideoBitrateBps("", 1920, 1080, 30), med);
}

TEST(ResolveVideoBitrateBpsTest, ScalesWithResolution) {
  EXPECT_LT(ResolveVideoBitrateBps("medium", 1280, 720, 30),
            ResolveVideoBitrateBps("medium", 1920, 1080, 30));
}

TEST(ResolveVideoBitrateBpsTest, ClampsToFloorAndCeiling) {
  EXPECT_EQ(ResolveVideoBitrateBps("low", 16, 16, 1), 2'000'000u);
  EXPECT_EQ(ResolveVideoBitrateBps("high", 7680, 4320, 60), 100'000'000u);
}

TEST(ResolveVideoBitrateBpsTest, ZeroFpsIsTreatedAs30) {
  EXPECT_EQ(ResolveVideoBitrateBps("medium", 1920, 1080, 0),
            ResolveVideoBitrateBps("medium", 1920, 1080, 30));
}

}  // namespace
}  // namespace clingfy::capture::export_
