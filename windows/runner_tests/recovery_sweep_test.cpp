#include "Services/recovery_sweep.h"

#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "Capture/recording_project_reader.h"
#include "Capture/recording_project_writer.h"

namespace clingfy::services {
namespace {

namespace fs = std::filesystem;

// Phase 10.4: the startup recovery sweep — marks crash-interrupted
// "capturing" bundles failed and removes stranded `%TEMP%\clingfy_*` files,
// with the PID-liveness + mtime guards that keep it from destroying a LIVE
// sibling instance's recording (dev + prod share both namespaces until
// Phase 10.5).

constexpr std::uint32_t kSelfPid = 7777;
constexpr std::uint32_t kDeadPid = 4444;
constexpr std::uint32_t kLivePid = 4242;

class RecoverySweepTest : public ::testing::Test {
 protected:
  void SetUp() override {
    root_ = fs::temp_directory_path() / L"clingfy_recovery_sweep_test";
    fs::remove_all(root_);
    recordings_ = root_ / L"recordings";
    temp_ = root_ / L"temp";
    fs::create_directories(recordings_);
    fs::create_directories(temp_);
  }
  void TearDown() override {
    std::error_code ec;
    fs::remove_all(root_, ec);
  }

  // Creates a provisional bundle exactly the way the engine does at record
  // start (same writer), then optionally rewrites its status.
  fs::path MakeBundle(const std::string& session_id, std::uint32_t owner_pid,
                      const std::string& status = "capturing") {
    capture::ProvisionalProjectInput input;
    input.session_id = session_id;
    input.recordings_root_override = recordings_.string();
    input.owner_pid = owner_pid;
    const auto result = capture::WriteProvisionalProject(input);
    EXPECT_EQ(result.kind, capture::ProjectWriterErrorKind::kNone);
    const fs::path bundle = fs::u8path(result.project_path);
    if (status != "capturing") {
      std::ifstream in(bundle / "project.json", std::ios::binary);
      std::ostringstream buf;
      buf << in.rdbuf();
      in.close();
      const auto rewritten =
          ReplaceJsonStringValue(buf.str(), "status", status);
      EXPECT_TRUE(rewritten.has_value());
      std::ofstream out(bundle / "project.json",
                        std::ios::binary | std::ios::trunc);
      out << *rewritten;
    }
    return bundle;
  }

  void TouchTemp(const std::string& name, const std::string& content = "x") {
    std::ofstream f(temp_ / fs::u8path(name),
                    std::ios::out | std::ios::binary);
    f << content;
  }

  std::string BundleStatus(const fs::path& bundle) {
    std::ifstream in(bundle / "project.json", std::ios::binary);
    std::ostringstream buf;
    buf << in.rdbuf();
    return capture::ProbeManifestStatus(buf.str()).status;
  }

  RecoverySweepOptions Options(bool everything_is_old) {
    RecoverySweepOptions options;
    options.recordings_root = recordings_.string();
    options.temp_dir = temp_.string();
    options.current_pid = kSelfPid;
    options.pid_is_live_clingfy = [](std::uint32_t pid) {
      return pid == kLivePid;
    };
    if (everything_is_old) {
      // Push "now" far past every just-written file's mtime so the age
      // guard treats them all as stale.
      options.now =
          fs::file_time_type::clock::now() + std::chrono::seconds(3600);
    } else {
      options.now = fs::file_time_type::clock::now();
    }
    return options;
  }

  fs::path root_;
  fs::path recordings_;
  fs::path temp_;
};

// ---- ReplaceJsonStringValue (pure) ----------------------------------------

TEST(ReplaceJsonStringValueTest, ValueLookalikeBeforeRealKeyIsSkipped) {
  // Review fix: a string VALUE whose bytes equal the needle (here the
  // displayName value is literally `"status"`) must not abort the scan —
  // the real key later in the document is still found.
  const std::string json =
      "{\n  \"displayName\": \"status\",\n  \"status\": \"capturing\"\n}";
  const auto out = ReplaceJsonStringValue(json, "status", "failed");
  ASSERT_TRUE(out.has_value());
  EXPECT_NE(out->find("\"status\": \"failed\""), std::string::npos);
  EXPECT_NE(out->find("\"displayName\": \"status\""), std::string::npos);
}

TEST(ReplaceJsonStringValueTest, ReplacesTopLevelValue) {
  const std::string json = "{\n  \"status\": \"capturing\",\n  \"x\": 1\n}";
  const auto out = ReplaceJsonStringValue(json, "status", "failed");
  ASSERT_TRUE(out.has_value());
  EXPECT_NE(out->find("\"status\": \"failed\""), std::string::npos);
  EXPECT_EQ(out->find("capturing"), std::string::npos);
}

TEST(ReplaceJsonStringValueTest, MissingKeyReturnsNullopt) {
  EXPECT_FALSE(
      ReplaceJsonStringValue("{\"a\": \"b\"}", "status", "failed").has_value());
}

TEST(ReplaceJsonStringValueTest, NonStringValueReturnsNullopt) {
  EXPECT_FALSE(
      ReplaceJsonStringValue("{\"status\": 3}", "status", "failed")
          .has_value());
}

TEST(ReplaceJsonStringValueTest, EscapedKeyLookalikeInsideValueIsNotMatched) {
  // A hostile displayName containing the literal text "status" with escaped
  // quotes must not be mistaken for the real key. The REAL status key later
  // in the document is still found and replaced.
  const std::string json =
      "{\n  \"displayName\": \"evil \\\"status\\\": \\\"ready\\\"\",\n"
      "  \"status\": \"capturing\"\n}";
  const auto out = ReplaceJsonStringValue(json, "status", "failed");
  ASSERT_TRUE(out.has_value());
  EXPECT_NE(out->find("\"status\": \"failed\""), std::string::npos);
  // The embedded lookalike inside displayName is untouched.
  EXPECT_NE(out->find("\\\"status\\\": \\\"ready\\\""), std::string::npos);
}

// ---- Marking ----------------------------------------------------------------

TEST_F(RecoverySweepTest, DeadOwnerCapturingBundleIsMarkedFailedAndReported) {
  const fs::path bundle = MakeBundle("crashed1", kDeadPid);
  const auto result = RunRecoverySweep(Options(/*everything_is_old=*/false));
  ASSERT_EQ(result.interrupted.size(), 1u);
  EXPECT_EQ(result.interrupted[0].session_id, "crashed1");
  EXPECT_EQ(BundleStatus(bundle), "failed");
}

TEST_F(RecoverySweepTest, FinalizingStatusIsAlsoMarkedFailed) {
  const fs::path bundle = MakeBundle("mid_final", kDeadPid, "finalizing");
  const auto result = RunRecoverySweep(Options(false));
  ASSERT_EQ(result.interrupted.size(), 1u);
  EXPECT_EQ(BundleStatus(bundle), "failed");
}

TEST_F(RecoverySweepTest, LiveOwnerBundleIsLeftAlone) {
  const fs::path bundle = MakeBundle("live1", kLivePid);
  const auto result = RunRecoverySweep(Options(false));
  EXPECT_TRUE(result.interrupted.empty());
  EXPECT_EQ(BundleStatus(bundle), "capturing");
}

TEST_F(RecoverySweepTest, ReadyAndFailedBundlesAreUntouched) {
  const fs::path ready = MakeBundle("done1", kDeadPid, "ready");
  const fs::path failed = MakeBundle("old_fail", kDeadPid, "failed");
  const auto result = RunRecoverySweep(Options(false));
  EXPECT_TRUE(result.interrupted.empty());
  EXPECT_EQ(BundleStatus(ready), "ready");
  EXPECT_EQ(BundleStatus(failed), "failed");
}

TEST_F(RecoverySweepTest, UnparseableManifestIsSkippedWithoutCrash) {
  const fs::path bundle = recordings_ / L"broken.clingfyproj";
  fs::create_directories(bundle);
  std::ofstream f(bundle / "project.json", std::ios::binary);
  f << "{ not json";
  f.close();
  const auto result = RunRecoverySweep(Options(false));
  EXPECT_TRUE(result.interrupted.empty());
}

// ---- Temp cleanup ------------------------------------------------------------

TEST_F(RecoverySweepTest, DeadOwnerTempsAreDeletedRegardlessOfAge) {
  MakeBundle("crashed2", kDeadPid);
  TouchTemp("clingfy_crashed2.mp4", "0123456789");
  TouchTemp("clingfy_crashed2.cursor.jsonl", "01234");
  TouchTemp("clingfy_crashed2.camera.mp4", "012");
  // now == file mtime → fresh — but the owner is provably dead, so the
  // age guard does not apply.
  const auto result = RunRecoverySweep(Options(/*everything_is_old=*/false));
  EXPECT_EQ(result.cleaned_temp_files, 3u);
  EXPECT_EQ(result.cleaned_temp_bytes, 18u);
  EXPECT_FALSE(fs::exists(temp_ / L"clingfy_crashed2.mp4"));
}

TEST_F(RecoverySweepTest, LiveOwnerTempsSurviveEvenWhenOld) {
  MakeBundle("live2", kLivePid);
  TouchTemp("clingfy_live2.mp4");
  const auto result = RunRecoverySweep(Options(/*everything_is_old=*/true));
  EXPECT_EQ(result.cleaned_temp_files, 0u);
  EXPECT_TRUE(fs::exists(temp_ / L"clingfy_live2.mp4"));
}

TEST_F(RecoverySweepTest, SelfOwnedBundleIsLeftEntirelyAlone) {
  // Review fix: our own pid counts as LIVE. A capturing bundle claiming it
  // is either a recording that started while the sweep walked the disk
  // (marking + reporting it "interrupted" would be flatly wrong) or a
  // PID-reuse leftover the NEXT launch (different pid) sweeps normally.
  const fs::path bundle = MakeBundle("self1", kSelfPid);
  TouchTemp("clingfy_self1.mp4");
  const auto result = RunRecoverySweep(Options(/*everything_is_old=*/true));
  EXPECT_TRUE(result.interrupted.empty());
  EXPECT_EQ(BundleStatus(bundle), "capturing");
  EXPECT_EQ(result.cleaned_temp_files, 0u);
  EXPECT_TRUE(fs::exists(temp_ / L"clingfy_self1.mp4"));
}

TEST_F(RecoverySweepTest, FailedBundleProtectsItsKeptTemps) {
  // Review fix (blocker): the engine deliberately keeps a finalized,
  // PLAYABLE temp when bundling fails and stamps the bundle "failed" —
  // the sweep must never age that file out as an "ownerless strand";
  // it is the only copy of the user's recording.
  MakeBundle("kept1", kDeadPid, "failed");
  TouchTemp("clingfy_kept1.mp4", "playable");
  TouchTemp("clingfy_kept1.camera.mp4", "cam");
  const auto result = RunRecoverySweep(Options(/*everything_is_old=*/true));
  EXPECT_TRUE(result.interrupted.empty());
  EXPECT_EQ(result.cleaned_temp_files, 0u);
  EXPECT_TRUE(fs::exists(temp_ / L"clingfy_kept1.mp4"));
  EXPECT_TRUE(fs::exists(temp_ / L"clingfy_kept1.camera.mp4"));
}

TEST_F(RecoverySweepTest, OwnerlessTempsAgeOut) {
  TouchTemp("clingfy_ancient.mp4", "0123456789");  // pre-10.4 strand
  TouchTemp("unrelated.txt");
  {
    const auto kept = RunRecoverySweep(Options(/*everything_is_old=*/false));
    EXPECT_EQ(kept.cleaned_temp_files, 0u);  // fresh → age guard keeps it
  }
  const auto swept = RunRecoverySweep(Options(/*everything_is_old=*/true));
  EXPECT_EQ(swept.cleaned_temp_files, 1u);
  EXPECT_EQ(swept.cleaned_temp_bytes, 10u);
  EXPECT_FALSE(fs::exists(temp_ / L"clingfy_ancient.mp4"));
  EXPECT_TRUE(fs::exists(temp_ / L"unrelated.txt"));
}

TEST_F(RecoverySweepTest, DiagnosticsZipsWithDashPrefixAreNeverTouched) {
  TouchTemp("clingfy-diagnostics-20260611.zip", "zip");
  const auto result = RunRecoverySweep(Options(/*everything_is_old=*/true));
  EXPECT_EQ(result.cleaned_temp_files, 0u);
  EXPECT_TRUE(fs::exists(temp_ / L"clingfy-diagnostics-20260611.zip"));
}

TEST_F(RecoverySweepTest, MissingRootsYieldEmptyResultWithoutCrash) {
  RecoverySweepOptions options;
  options.recordings_root = (root_ / L"nope").string();
  options.temp_dir = (root_ / L"nope2").string();
  options.current_pid = kSelfPid;
  options.pid_is_live_clingfy = [](std::uint32_t) { return false; };
  const auto result = RunRecoverySweep(options);
  EXPECT_TRUE(result.interrupted.empty());
  EXPECT_EQ(result.cleaned_temp_files, 0u);
}

// ---- BundleOwnedByLiveProcess (clearCachedRecordings guard) -----------------

TEST_F(RecoverySweepTest, BundleOwnedByLiveProcessDetectsLiveForeignOwner) {
  const fs::path live = MakeBundle("guard_live", kLivePid);
  const fs::path dead = MakeBundle("guard_dead", kDeadPid);
  const fs::path self = MakeBundle("guard_self", kSelfPid);
  const fs::path ready = MakeBundle("guard_ready", kLivePid, "ready");
  const auto probe = [](std::uint32_t pid) { return pid == kLivePid; };
  EXPECT_TRUE(BundleOwnedByLiveProcess(live, kSelfPid, probe));
  EXPECT_FALSE(BundleOwnedByLiveProcess(dead, kSelfPid, probe));
  EXPECT_FALSE(BundleOwnedByLiveProcess(self, kSelfPid, probe));
  EXPECT_FALSE(BundleOwnedByLiveProcess(ready, kSelfPid, probe));
  EXPECT_FALSE(BundleOwnedByLiveProcess(recordings_ / L"missing.clingfyproj",
                                        kSelfPid, probe));
}

}  // namespace
}  // namespace clingfy::services
