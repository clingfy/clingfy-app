// Per-channel application identity (D9).
//
// dev and prod shipped sharing BOTH their single-instance mutex and every
// on-disk directory, so installing them side by side meant one channel could
// not start while the other ran, and whichever did run read and wrote the
// other's settings, recordings and logs. The tester guide warned against
// side-by-side installs rather than the build making them safe.
//
// Every identity now derives from one channel value, resolved at compile time
// from the `CLINGFY_CHANNEL` define that `01_build.ps1` plumbs through CMake.
//
// THE INVARIANT THAT MATTERS: prod's identity is byte-for-byte what shipped
// before this existed. A change there does not "rename a folder" — it orphans
// every existing user's recordings and settings, silently, on upgrade. Any
// unrecognised or absent channel therefore resolves to prod, because the cost
// of guessing wrong in that direction is a dev build sharing prod's data (a
// developer's problem) rather than a released build losing a user's work.

#ifndef RUNNER_CORE_APP_IDENTITY_H_
#define RUNNER_CORE_APP_IDENTITY_H_

#include <string>

namespace clingfy::core {

enum class AppChannel {
  kProd,
  kDev,
};

// Pure: maps a channel token (the `-Channel` value the release lane uses) to
// the channel. Unknown, empty, or differently-cased input resolves to prod.
AppChannel ResolveChannel(const std::string& token);

// The channel this binary was built for. Compile-time; see CLINGFY_CHANNEL.
AppChannel CurrentChannel();

// Directory name under %LOCALAPPDATA% holding recordings, logs and caches.
//
// prod: "Clingfy"      — UNCHANGED from every previously shipped build.
// dev:  "Clingfy Dev"
std::wstring LocalAppDataFolderName(AppChannel channel);

// Suffix for the single-instance mutex and the receiver window class.
//
// prod: "com.clingfy.clingfy"      — UNCHANGED.
// dev:  "com.clingfy.clingfy.dev"
//
// Distinct values are what let both channels run at once; sharing one meant
// launching dev silently forwarded the command line into a running prod
// instance and exited.
std::wstring InstanceMutexSuffix(AppChannel channel);

// User-visible product name: what a person reads in the window title bar and
// in Task Manager.
//
// prod: "Clingfy"   dev: "Clingfy Dev"
//
// Distinct from ProductName in the version resource, which is FROZEN because
// path_provider derives the data directory from it. This one is display text
// and safe to change; that one is an identity and is not.
//
// Channel-aware because D9 made side-by-side installs safe: two windows both
// titled "Clingfy" would be a worse bug than the lowercase title this
// replaces.
std::wstring DisplayName(AppChannel channel);

// Convenience wrappers for the channel this binary was built for.
std::wstring LocalAppDataFolderName();
std::wstring InstanceMutexSuffix();
std::wstring DisplayName();

}  // namespace clingfy::core

#endif  // RUNNER_CORE_APP_IDENTITY_H_
