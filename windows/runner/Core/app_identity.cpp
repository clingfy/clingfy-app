#include "Core/app_identity.h"

#include <algorithm>
#include <cctype>

namespace clingfy::core {

namespace {

std::string ToLowerAscii(const std::string& value) {
  std::string out = value;
  std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return out;
}

}  // namespace

AppChannel ResolveChannel(const std::string& token) {
  // ONLY an exact "dev" opts out of prod. Everything else — empty, unknown,
  // a typo, a future channel name this binary predates — is prod, because
  // guessing dev for a released build would point it at a directory the user's
  // recordings are not in.
  return ToLowerAscii(token) == "dev" ? AppChannel::kDev : AppChannel::kProd;
}

AppChannel CurrentChannel() {
#ifdef CLINGFY_CHANNEL
  return ResolveChannel(CLINGFY_CHANNEL);
#else
  // No define means a plain `flutter build windows` / IDE build. Prod identity
  // keeps a developer's local build pointed at the same data as an installed
  // release, which is the behaviour that existed before this file.
  return AppChannel::kProd;
#endif
}

std::wstring LocalAppDataFolderName(AppChannel channel) {
  // Hyphen, not a space. This name ends up in paths that get typed, pasted
  // into scripts, and passed to command-line tools --
  // %LOCALAPPDATA%\Clingfy-Dev\recordings -- where a space means every
  // consumer has to remember to quote it, and the ones that forget fail in
  // ways that look like a missing directory. DisplayName keeps the space:
  // that one is read by humans, never typed.
  //
  // Note what this change WAS, because the sibling edit in Runner.rc was a
  // different thing and the two are easy to conflate. Dev here shipped as
  // "Clingfy Dev" with a space; "Clingfy-Dev" is a REAL rename, not a case
  // change, and NTFS case-insensitivity does not bridge a space to a hyphen.
  // Anything a dev build had written under the old path was orphaned. That
  // was acceptable only because no distributed build ever used it -- the
  // spaced name landed in #373 (2026-07-28) and the dev feed was still
  // 1.0.6+111 from about a week earlier, so it existed on local dev machines
  // and nowhere else. Renaming this for prod, or for dev once a dev build
  // ships with a given name, orphans real recordings and logs.
  return channel == AppChannel::kDev ? L"Clingfy-Dev" : L"Clingfy";
}

std::wstring InstanceMutexSuffix(AppChannel channel) {
  return channel == AppChannel::kDev ? L"com.clingfy.clingfy.dev"
                                     : L"com.clingfy.clingfy";
}

std::wstring DisplayName(AppChannel channel) {
  return channel == AppChannel::kDev ? L"Clingfy Dev" : L"Clingfy";
}

std::wstring LocalAppDataFolderName() {
  return LocalAppDataFolderName(CurrentChannel());
}

std::wstring DisplayName() { return DisplayName(CurrentChannel()); }

std::wstring InstanceMutexSuffix() {
  return InstanceMutexSuffix(CurrentChannel());
}

}  // namespace clingfy::core
