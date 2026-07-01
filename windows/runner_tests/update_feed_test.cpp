#include "Updater/update_feed.h"

#include <gtest/gtest.h>

#include <string>

// Phase 10.6 — pure feed parse + version compare + decision tests. The
// sample body below is the VERBATIM shape 04_publish_azure.ps1 writes
// (ConvertTo-Json of the ordered hashtable), so a pipeline shape change
// that breaks the client parse fails here first.
namespace clingfy::updater {
namespace {

constexpr char kPublishedFeed[] = R"({
  "version": "1.0.5",
  "build": 7,
  "versionFull": "1.0.5+7",
  "channel": "dev",
  "platform": "windows-x64",
  "fileName": "Clingfy_Dev_Setup_1.0.5+7.exe",
  "url": "https://clingfy-downloads-dev.example.azurefd.net/downloads/windows/Clingfy_Dev_Setup_1.0.5+7.exe",
  "sha256": "0123456789abcdef",
  "sizeBytes": 52428800,
  "minimumOsVersion": "10.0.18362",
  "publishedAt": "2026-06-12T12:00:00Z"
})";

AppVersion Version(int major, int minor, int patch, std::int64_t build = 0) {
  AppVersion v;
  v.major = major;
  v.minor = minor;
  v.patch = patch;
  v.build = build;
  return v;
}

// ---- ParseUpdateFeed -------------------------------------------------

TEST(UpdateFeedParseTest, ParsesThePublishedPipelineShape) {
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);
  EXPECT_TRUE(feed.parsed);
  EXPECT_EQ(feed.version, "1.0.5");
  EXPECT_EQ(feed.build, 7);
  EXPECT_EQ(feed.version_full, "1.0.5+7");
  EXPECT_EQ(feed.channel, "dev");
  EXPECT_EQ(feed.platform, "windows-x64");
  EXPECT_EQ(feed.url,
            "https://clingfy-downloads-dev.example.azurefd.net/downloads/"
            "windows/Clingfy_Dev_Setup_1.0.5+7.exe");
  EXPECT_EQ(feed.sha256, "0123456789abcdef");
  EXPECT_EQ(feed.size_bytes, 52428800);
  EXPECT_EQ(feed.published_at, "2026-06-12T12:00:00Z");
}

TEST(UpdateFeedParseTest, RejectsNonObjectBodies) {
  EXPECT_FALSE(ParseUpdateFeed("").parsed);
  EXPECT_FALSE(ParseUpdateFeed("   \n ").parsed);
  EXPECT_FALSE(ParseUpdateFeed("[1,2,3]").parsed);
  EXPECT_FALSE(ParseUpdateFeed("<html>service unavailable</html>").parsed);
  EXPECT_FALSE(ParseUpdateFeed("{\"version\": \"1.0.5\"").parsed);
}

TEST(UpdateFeedParseTest, MissingFieldsKeepDefaults) {
  const UpdateFeed feed = ParseUpdateFeed("{\"version\": \"1.0.5\"}");
  EXPECT_TRUE(feed.parsed);
  EXPECT_EQ(feed.version, "1.0.5");
  EXPECT_EQ(feed.build, -1);
  EXPECT_TRUE(feed.url.empty());
  EXPECT_TRUE(feed.channel.empty());
  EXPECT_EQ(feed.size_bytes, -1);
}

TEST(UpdateFeedParseTest, KeyShapedSubstringInsideValueIsNotAKey) {
  // The 9.4 lesson: remote text must not be able to masquerade as a key.
  // Here the fileName VALUE contains a `"version":`-shaped substring; the
  // real version key is absent, so version must stay empty.
  const std::string body =
      "{\"fileName\": \"evil \\\"version\\\": \\\"9.9.9\\\" name\","
      "\"build\": 3}";
  const UpdateFeed feed = ParseUpdateFeed(body);
  EXPECT_TRUE(feed.parsed);
  EXPECT_TRUE(feed.version.empty());
  EXPECT_EQ(feed.build, 3);
}

TEST(UpdateFeedParseTest, NestedObjectKeysAreNotTopLevelKeys) {
  const std::string body =
      "{\"extra\": {\"version\": \"9.9.9\"}, \"version\": \"1.2.3\"}";
  const UpdateFeed feed = ParseUpdateFeed(body);
  EXPECT_TRUE(feed.parsed);
  EXPECT_EQ(feed.version, "1.2.3");
}

TEST(UpdateFeedParseTest, OverflowingBuildIsRejectedNotSaturated) {
  // strtoll saturates to LLONG_MAX with errno=ERANGE; the parser must
  // reject the field (build stays -1) instead of accepting LLONG_MAX as a
  // real build that would win every same-version comparison.
  const UpdateFeed feed = ParseUpdateFeed(
      "{\"version\": \"1.0.4\", \"build\": 99999999999999999999999}");
  EXPECT_TRUE(feed.parsed);
  EXPECT_EQ(feed.build, -1);
}

// ---- SanitizeForEvent ---------------------------------------------------

TEST(UpdateSanitizeTest, ValidTextPassesThrough) {
  EXPECT_EQ(SanitizeForEvent("1.0.5+7"), "1.0.5+7");
  // Valid two-byte UTF-8 ("é") survives intact.
  EXPECT_EQ(SanitizeForEvent("caf\xC3\xA9"), "caf\xC3\xA9");
}

TEST(UpdateSanitizeTest, InvalidBytesBecomeQuestionMarks) {
  // Lone invalid byte, truncated lead at end-of-string, and a surrogate
  // encoding (what a strict UTF-8 decoder like Dart's rejects).
  EXPECT_EQ(SanitizeForEvent("a\xFF"
                             "b"),
            "a?b");
  EXPECT_EQ(SanitizeForEvent("end\xE2"), "end?");
  EXPECT_EQ(SanitizeForEvent("\xED\xA0\x80"), "???");
  // Overlong lead bytes are invalid.
  EXPECT_EQ(SanitizeForEvent("\xC0\xAF"), "??");
}

TEST(UpdateSanitizeTest, CapsLengthWithoutSplittingCharacters) {
  EXPECT_EQ(SanitizeForEvent("abcdef", 4), "abcd");
  // The two-byte character does not fit in the last byte of the budget —
  // it is dropped whole, never split into an invalid half.
  EXPECT_EQ(SanitizeForEvent("abc\xC3\xA9", 4), "abc");
}

// ---- ParseVersionString ----------------------------------------------

TEST(UpdateVersionParseTest, ParsesPlainTriples) {
  const auto v = ParseVersionString("1.0.4");
  ASSERT_TRUE(v.has_value());
  EXPECT_EQ(v->major, 1);
  EXPECT_EQ(v->minor, 0);
  EXPECT_EQ(v->patch, 4);
  EXPECT_EQ(v->build, 0);
}

TEST(UpdateVersionParseTest, RejectsMalformedVersions) {
  EXPECT_FALSE(ParseVersionString("").has_value());
  EXPECT_FALSE(ParseVersionString("1.0").has_value());
  EXPECT_FALSE(ParseVersionString("1.0.4.2").has_value());
  EXPECT_FALSE(ParseVersionString("1.0.4-beta").has_value());
  EXPECT_FALSE(ParseVersionString("v1.0.4").has_value());
  EXPECT_FALSE(ParseVersionString("1..4").has_value());
  EXPECT_FALSE(ParseVersionString("1.0.99999999").has_value());
}

// ---- FeedIsNewer -------------------------------------------------------

TEST(UpdateCompareTest, ComparesVersionTuplesThenBuild) {
  EXPECT_TRUE(FeedIsNewer(Version(2, 0, 0), Version(1, 9, 9, 100)));
  EXPECT_TRUE(FeedIsNewer(Version(1, 1, 0), Version(1, 0, 9)));
  EXPECT_TRUE(FeedIsNewer(Version(1, 0, 5), Version(1, 0, 4)));
  EXPECT_TRUE(FeedIsNewer(Version(1, 0, 4, 6), Version(1, 0, 4, 5)));
  EXPECT_FALSE(FeedIsNewer(Version(1, 0, 4, 5), Version(1, 0, 4, 5)));
  EXPECT_FALSE(FeedIsNewer(Version(1, 0, 4, 4), Version(1, 0, 4, 5)));
  EXPECT_FALSE(FeedIsNewer(Version(1, 0, 3, 99), Version(1, 0, 4)));
  // A lower version with a huge build is still older.
  EXPECT_FALSE(FeedIsNewer(Version(0, 9, 9, 65535), Version(1, 0, 0)));
}

// ---- EvaluateUpdateFeed -------------------------------------------------

TEST(UpdateEvaluateTest, NewerFeedIsAnAvailableUpdate) {
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);
  const UpdateDecision d = EvaluateUpdateFeed(feed, "dev", Version(1, 0, 4, 5));
  EXPECT_EQ(d.action, UpdateDecision::Action::kUpdateAvailable);
}

TEST(UpdateEvaluateTest, SameVersionSameBuildIsNoUpdate) {
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);
  const UpdateDecision d = EvaluateUpdateFeed(feed, "dev", Version(1, 0, 5, 7));
  EXPECT_EQ(d.action, UpdateDecision::Action::kNoUpdate);
}

TEST(UpdateEvaluateTest, OlderFeedIsNoUpdate) {
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);
  const UpdateDecision d = EvaluateUpdateFeed(feed, "dev", Version(1, 0, 6));
  EXPECT_EQ(d.action, UpdateDecision::Action::kNoUpdate);
}

TEST(UpdateEvaluateTest, SameVersionNewerBuildIsAnUpdate) {
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);
  const UpdateDecision d = EvaluateUpdateFeed(feed, "dev", Version(1, 0, 5, 6));
  EXPECT_EQ(d.action, UpdateDecision::Action::kUpdateAvailable);
}

TEST(UpdateEvaluateTest, MalformedFeedIsAnError) {
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("<html>oops</html>"), "dev", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kError);
  EXPECT_EQ(d.code, codes::kFeedMalformed);
}

TEST(UpdateEvaluateTest, UnparsableFeedVersionIsAnError) {
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"latest\", \"platform\": "
                      "\"windows-x64\"}"),
      "", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kError);
  EXPECT_EQ(d.code, codes::kFeedMalformed);
}

TEST(UpdateEvaluateTest, PlatformMismatchIsAnError) {
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"9.9.9\", \"platform\": \"macos\"}"),
      "", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kError);
  EXPECT_EQ(d.code, codes::kFeedMismatch);
}

TEST(UpdateEvaluateTest, ChannelMismatchIsAnErrorWhenExpectedIsSet) {
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);  // channel: dev
  const UpdateDecision d =
      EvaluateUpdateFeed(feed, "prod", Version(1, 0, 4, 5));
  EXPECT_EQ(d.action, UpdateDecision::Action::kError);
  EXPECT_EQ(d.code, codes::kFeedMismatch);
}

TEST(UpdateEvaluateTest, ChannelIsIgnoredWhenNoExpectationProvided) {
  // Per-channel Front Door domains are the primary isolation; an empty
  // expected channel (older Dart, tests) skips the secondary check.
  const UpdateFeed feed = ParseUpdateFeed(kPublishedFeed);
  const UpdateDecision d = EvaluateUpdateFeed(feed, "", Version(1, 0, 4, 5));
  EXPECT_EQ(d.action, UpdateDecision::Action::kUpdateAvailable);
}

TEST(UpdateEvaluateTest, MissingFeedChannelSkipsTheChannelCheck) {
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"9.9.9\", \"platform\": "
                      "\"windows-x64\", \"url\": \"https://x.example/i.exe\""
                      "}"),
      "dev", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kUpdateAvailable);
}

TEST(UpdateEvaluateTest, NewerFeedWithoutUrlIsAnError) {
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"9.9.9\", \"platform\": "
                      "\"windows-x64\", \"channel\": \"dev\"}"),
      "dev", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kError);
  EXPECT_EQ(d.code, codes::kUrlMissing);
}

TEST(UpdateEvaluateTest, NewerFeedWithNonHttpsUrlIsAnError) {
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"9.9.9\", \"platform\": "
                      "\"windows-x64\", \"url\": \"http://x.example/i.exe\""
                      "}"),
      "", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kError);
  EXPECT_EQ(d.code, codes::kUrlMissing);
}

TEST(UpdateEvaluateTest, OlderFeedWithoutUrlIsStillNoUpdate) {
  // The URL is only required when we would actually advertise an update.
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"0.0.1\", \"platform\": "
                      "\"windows-x64\"}"),
      "", Version(1, 0, 4));
  EXPECT_EQ(d.action, UpdateDecision::Action::kNoUpdate);
}

TEST(UpdateEvaluateTest, MissingFeedBuildIsTreatedAsZero) {
  // Same version, feed build missing (-1 -> 0), current build 5: no update.
  const UpdateDecision d = EvaluateUpdateFeed(
      ParseUpdateFeed("{\"version\": \"1.0.4\", \"platform\": "
                      "\"windows-x64\", \"url\": \"https://x.example/i.exe\""
                      "}"),
      "", Version(1, 0, 4, 5));
  EXPECT_EQ(d.action, UpdateDecision::Action::kNoUpdate);
}

}  // namespace
}  // namespace clingfy::updater
