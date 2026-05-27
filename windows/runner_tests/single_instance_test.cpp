// Scope: covers the pieces of single_instance.{h,cpp} that don't require
// a second OS process. Specifically:
//
//   * `DecodeProjectOpenPayload` — pure parsing of a COPYDATASTRUCT body
//   * `NormalizeProjectPathPayload` — pass-through today, gated against
//     future regressions where someone forgets the null terminator
//
// The mutex + WindowFinder + SendMessage round-trip is validated
// end-to-end by the running app and a manual smoke (launching a second
// clingfy.exe with an argv path). Spawning a child process from a
// unit test is doable but doubles the build/test surface and the
// receiver-side logic is already exercised by the decode test below.

#include "Core/single_instance.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <cstring>
#include <string>
#include <vector>

namespace clingfy::core {
namespace {

TEST(SingleInstanceTest, DecodeWmCopyDataRoundTrip) {
  const std::wstring path = L"C:\\some\\path.clingfyproj";
  COPYDATASTRUCT cds{};
  cds.dwData = kProjectOpenWmCopyDataId;
  // Include the trailing null in cbData so the receiver-side string
  // bound is honoured.
  cds.cbData = static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t));
  cds.lpData = const_cast<wchar_t*>(path.c_str());
  EXPECT_EQ(DecodeProjectOpenPayload(&cds), path);
}

TEST(SingleInstanceTest, DecodeRejectsForeignDwData) {
  const std::wstring path = L"C:\\does-not-matter.clingfyproj";
  COPYDATASTRUCT cds{};
  cds.dwData = 0xDEADBEEF;  // not our magic id
  cds.cbData = static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t));
  cds.lpData = const_cast<wchar_t*>(path.c_str());
  EXPECT_TRUE(DecodeProjectOpenPayload(&cds).empty());
}

TEST(SingleInstanceTest, DecodeHandlesMissingNullTerminator) {
  // cbData covers only the characters, no terminating null. The
  // decoder must still produce a clean string by trimming at the
  // declared length rather than walking off the end.
  const std::wstring path = L"C:\\no-null.clingfyproj";
  COPYDATASTRUCT cds{};
  cds.dwData = kProjectOpenWmCopyDataId;
  cds.cbData = static_cast<DWORD>(path.size() * sizeof(wchar_t));
  cds.lpData = const_cast<wchar_t*>(path.c_str());
  EXPECT_EQ(DecodeProjectOpenPayload(&cds), path);
}

TEST(SingleInstanceTest, DecodeEmptyAndNullSafe) {
  EXPECT_TRUE(DecodeProjectOpenPayload(nullptr).empty());
  COPYDATASTRUCT cds{};
  cds.dwData = kProjectOpenWmCopyDataId;
  cds.cbData = 0;
  cds.lpData = nullptr;
  EXPECT_TRUE(DecodeProjectOpenPayload(&cds).empty());
}

TEST(SingleInstanceTest, NormalizeProjectPathPayloadPassesThroughToday) {
  // The normalization helper is a future-proofing seam; for now it
  // round-trips paths unchanged. This test exists so a future change
  // that silently strips quotes / lowercases / etc. doesn't slip in
  // without an explicit acknowledgement.
  const std::wstring p = L"C:\\Users\\me\\Recording.clingfyproj";
  EXPECT_EQ(NormalizeProjectPathPayload(p), p);
}

TEST(SingleInstanceTest, AcquireMutexFirstCallReturnsTrue) {
  // The named mutex is process-lifetime; the first call in any test
  // process is the "first instance". A second call in the same
  // process is benign (the production code only calls this once).
  EXPECT_TRUE(TryAcquireInstanceMutex(L"runner_tests"));
}

}  // namespace
}  // namespace clingfy::core
