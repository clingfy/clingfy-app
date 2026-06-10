#ifndef RUNNER_SERVICES_LOG_LOCATIONS_H_
#define RUNNER_SERVICES_LOG_LOCATIONS_H_

#include <string>

namespace clingfy::storage {

// Phase 10.1: stable, install-location-independent log paths.
//
// Native diagnostics used to write to the CWD-relative `build\windows-poc\`
// — fine on a dev checkout, silently dropped (or littered into a random
// CWD) for an installed app launched from Explorer. Everything now resolves
// under the user profile via the Known Folder API:
//
//   * Native logs  → %LOCALAPPDATA%\Clingfy\Logs
//   * Dart logs    → %APPDATA%\<CompanyName>\<ProductName>\Logs
//                    (the directory `path_provider`'s
//                    getApplicationSupportDirectory resolves on Windows —
//                    it reads CompanyName/ProductName from the exe's
//                    version resource, so we read the same resource instead
//                    of hardcoding. CAVEAT for the Phase 10.5 branding
//                    rename: parity holds only while Runner.rc keeps BOTH
//                    strings present, free of the characters path_provider
//                    sanitizes (<>:"/\|?* and trailing dots/spaces), and in
//                    the 0409 translation — path_provider's missing-field
//                    fallbacks (drop the company level / use the exe
//                    basename) differ from ours, which substitutes the
//                    historical com.clingfy/clingfy identity.)

// Pure joiners — testable without touching the OS.
std::wstring JoinNativeLogsDir(const std::wstring& local_app_data);
std::wstring JoinDartLogsDir(const std::wstring& roaming_app_data,
                             const std::wstring& company,
                             const std::wstring& product);
// FileLogSink writes `logs_YYYY-MM-DD.jsonl` (local date, zero-padded).
std::wstring DartLogFileNameForDate(int year, int month, int day);

// Resolvers. Empty string when unresolvable (no profile dirs at all) —
// callers treat that as "logging unavailable", never as an error.
//
// NativeLogsDirectory honors the CLINGFY_NATIVE_LOG_DIR env override
// (tests + support escalations) on every call; the Known Folder lookup
// behind it is resolved once and cached.
std::wstring NativeLogsDirectory();
// The directory the Dart FileLogSink writes JSONL logs into. Resolved from
// FOLDERID_RoamingAppData + the exe's version-resource company/product
// (fallback "com.clingfy"/"clingfy" when the resource is unreadable).
// Honors the CLINGFY_DART_LOG_DIR env override on every call (tests).
std::wstring DartLogsDirectory();
// Today's Dart JSONL log file (local date). Existence is NOT checked.
std::wstring TodayDartLogFilePath();

}  // namespace clingfy::storage

#endif  // RUNNER_SERVICES_LOG_LOCATIONS_H_
