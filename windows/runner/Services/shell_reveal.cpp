#include "Services/shell_reveal.h"

// clang-format off: windows.h must precede shellapi.h/shlobj.h.
#include <windows.h>

#include <shellapi.h>
#include <shlobj.h>
// clang-format on

#include <filesystem>

namespace clingfy::storage {

RevealAction ResolveRevealAction(bool path_exists, bool is_directory) {
  if (!path_exists) {
    return RevealAction::kNone;
  }
  return is_directory ? RevealAction::kOpenFolder
                      : RevealAction::kSelectInFolder;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return {};
  }
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), out.data(), needed);
  return out;
}

// Test seam: gtest exercises the storage_router handlers end-to-end, and a
// real ShellExecuteW would pop Explorer windows on every test run. When the
// variable is set the launch is skipped and reported as successful — the
// handlers' gating/error logic is what the tests pin.
bool SuppressShellOpenForTesting() {
  return ::GetEnvironmentVariableW(L"CLINGFY_SUPPRESS_SHELL_OPEN", nullptr,
                                   0) > 0;
}

bool OpenFolderInExplorer(const std::wstring& folder) {
  if (folder.empty()) {
    return false;
  }
  if (SuppressShellOpenForTesting()) {
    return true;
  }
  // ShellExecuteW returns a pseudo-HINSTANCE > 32 on success.
  const auto rc = reinterpret_cast<INT_PTR>(::ShellExecuteW(
      nullptr, L"open", folder.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
  return rc > 32;
}

bool SelectInExplorer(const std::wstring& file) {
  if (file.empty()) {
    return false;
  }
  if (SuppressShellOpenForTesting()) {
    return true;
  }
  // COM is already initialized on the platform thread (the save-folder
  // IFileOpenDialog relies on the same fact).
  PIDLIST_ABSOLUTE item = ::ILCreateFromPathW(file.c_str());
  if (item != nullptr) {
    const HRESULT hr = ::SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    ::ILFree(item);
    if (SUCCEEDED(hr)) {
      return true;
    }
  }
  // Fallback: open the parent folder without selection.
  const std::filesystem::path parent = std::filesystem::path(file).parent_path();
  if (parent.empty()) {
    return false;
  }
  return OpenFolderInExplorer(parent.wstring());
}

}  // namespace clingfy::storage
