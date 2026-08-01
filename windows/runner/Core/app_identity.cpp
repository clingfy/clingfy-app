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
  return channel == AppChannel::kDev ? L"Clingfy Dev" : L"Clingfy";
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
