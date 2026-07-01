#ifndef RUNNER_UPDATER_UPDATE_CHECKER_H_
#define RUNNER_UPDATER_UPDATE_CHECKER_H_

#include <functional>
#include <optional>
#include <string>

#include "Updater/update_feed.h"

// Phase 10.6 — the async half of the private-beta update check (D2).
//
// `StartUpdateCheck` validates the feed URL, then runs the fetch + parse +
// compare pipeline on a single worker thread and reports results through
// `UpdaterEventPublisher` (checking -> updateAvailable / noUpdateAvailable /
// updateError). It never blocks the platform thread.
//
// Lifetime mirrors the 10.1 temp_orphan_scan holder pattern: the worker
// thread lives in a function-local static holder whose constructor runs
// AFTER the publisher / log / dispatcher singletons are force-initialized,
// so CRT reverse-destruction joins the worker while everything it touches
// is still alive. The holder's cancel flag is polled between WinHTTP calls
// and a 30s total deadline bounds the read loop, so an app quit mid-check
// joins within one in-flight WinHTTP call (<= ~15s worst case, typically
// instant).
namespace clingfy::updater {

struct FetchResult {
  bool ok = false;
  std::string body;
  std::string error;  // human-readable failure detail when !ok
};

using Fetcher = std::function<FetchResult(const std::string& url)>;

// Starts an async update check. Returns false when the URL is empty or not
// https (an `updateError` event is emitted so the UI never goes silent).
// Returns true when the check was started — or when one is already in
// flight, in which case the in-flight check's events stand and no second
// thread is spawned.
bool StartUpdateCheck(const std::string& feed_url,
                      const std::string& expected_channel);

// Reads major.minor.patch+build from the running exe's VS_FIXEDFILEINFO
// (Runner.rc packs pubspec's x.y.z+build into FILEVERSION; the release
// pipeline guards build <= 65535). nullopt when the executable has no
// version resource — runner_tests.exe, for example.
std::optional<AppVersion> CurrentAppVersionFromExe();

// --- test seams -----------------------------------------------------------

// Replaces the WinHTTP fetcher (null restores the real one).
void SetUpdateFetcherForTesting(Fetcher fetcher);
// Overrides CurrentAppVersionFromExe. Passing nullopt forces the
// "no version resource" path deterministically (the test exe may or may
// not carry one); ClearCurrentVersionOverrideForTesting restores the real
// read.
void SetCurrentVersionForTesting(std::optional<AppVersion> version);
void ClearCurrentVersionOverrideForTesting();
// Joins the worker so tests can assert emitted events deterministically.
void JoinUpdateCheckForTesting();

}  // namespace clingfy::updater

#endif  // RUNNER_UPDATER_UPDATE_CHECKER_H_
