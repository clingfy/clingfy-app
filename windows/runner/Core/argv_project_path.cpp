#include "Core/argv_project_path.h"

#include <windows.h>
#include <shellapi.h>

#include <cwctype>

namespace clingfy::core {

namespace {

constexpr wchar_t kExtension[] = L".clingfyproj";
constexpr size_t kExtensionLen = sizeof(kExtension) / sizeof(wchar_t) - 1;

bool EndsWithExtensionCaseInsensitive(const std::wstring& s) {
  if (s.size() < kExtensionLen) return false;
  const size_t offset = s.size() - kExtensionLen;
  for (size_t i = 0; i < kExtensionLen; ++i) {
    const wchar_t a =
        static_cast<wchar_t>(std::towlower(static_cast<wint_t>(s[offset + i])));
    const wchar_t b =
        static_cast<wchar_t>(std::towlower(static_cast<wint_t>(kExtension[i])));
    if (a != b) return false;
  }
  return true;
}

bool LooksLikeFlag(const std::wstring& arg) {
  if (arg.empty()) return false;
  // Treat "/" prefix as a flag on Windows (legacy convention) — Flutter
  // itself uses "--foo" style, but accepting both keeps the heuristic
  // robust against future tooling.
  return arg[0] == L'-' || arg[0] == L'/';
}

}  // namespace

std::optional<std::wstring> ExtractClingfyProjPath(
    const std::vector<std::wstring>& argv) {
  for (const auto& arg : argv) {
    if (LooksLikeFlag(arg)) continue;
    if (EndsWithExtensionCaseInsensitive(arg)) {
      return arg;
    }
  }
  return std::nullopt;
}

std::optional<std::wstring> ExtractClingfyProjPathFromCommandLine(
    const wchar_t* command_line) {
  if (command_line == nullptr || command_line[0] == L'\0') {
    return std::nullopt;
  }
  int argc = 0;
  // `wWinMain`'s command_line does not contain argv[0]; we still pass
  // the bare cmdline to CommandLineToArgvW which honours that contract.
  LPWSTR* argv_raw = ::CommandLineToArgvW(command_line, &argc);
  if (argv_raw == nullptr || argc <= 0) {
    if (argv_raw != nullptr) ::LocalFree(argv_raw);
    return std::nullopt;
  }

  std::vector<std::wstring> argv;
  argv.reserve(static_cast<size_t>(argc));
  for (int i = 0; i < argc; ++i) {
    argv.emplace_back(argv_raw[i] ? argv_raw[i] : L"");
  }
  ::LocalFree(argv_raw);

  return ExtractClingfyProjPath(argv);
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string{};
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr,
      nullptr);
  if (needed <= 0) return std::string{};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                        out.data(), needed, nullptr, nullptr);
  return out;
}

}  // namespace clingfy::core
