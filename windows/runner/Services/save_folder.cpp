#include "Services/save_folder.h"

#include <objbase.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <filesystem>

namespace clingfy::storage {

namespace {

namespace fs = std::filesystem;

// Read an environment variable into a wstring. Empty when unset/empty.
std::wstring ReadEnv(const wchar_t* name) {
  const DWORD needed = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (needed <= 1) {
    // 0 = not set; 1 = empty string (just the null terminator).
    return {};
  }
  std::wstring value(needed, L'\0');
  const DWORD written = ::GetEnvironmentVariableW(name, value.data(), needed);
  if (written == 0 || written >= needed) {
    return {};
  }
  value.resize(written);
  return value;
}

}  // namespace

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return {};
  }
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) {
    return {};
  }
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        out.data(), needed, nullptr, nullptr);
  return out;
}

std::wstring DefaultSaveFolder() {
  // 1. Explicit override (tests + power users).
  const std::wstring override_path = ReadEnv(L"CLINGFY_DEFAULT_SAVE_FOLDER");
  if (!override_path.empty()) {
    return override_path;
  }

  // 2. Known Videos folder + Clingfy subfolder (analog of ~/Movies/Clingfy).
  PWSTR videos = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_Videos, 0, nullptr, &videos)) &&
      videos != nullptr) {
    std::wstring base(videos);
    ::CoTaskMemFree(videos);
    if (!base.empty()) {
      return base + L"\\Clingfy";
    }
  } else if (videos != nullptr) {
    ::CoTaskMemFree(videos);
  }

  // 3. Last-resort %USERPROFILE%\Videos\Clingfy.
  const std::wstring profile = ReadEnv(L"USERPROFILE");
  if (!profile.empty()) {
    return profile + L"\\Videos\\Clingfy";
  }
  return {};
}

std::string DefaultSaveFolderUtf8() { return WideToUtf8(DefaultSaveFolder()); }

bool EnsureDirectoryExists(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  const fs::path dir(path);
  std::error_code ec;
  fs::create_directories(dir, ec);
  // create_directories returns false (with no error) when the directory
  // already existed, so check existence rather than the return value.
  return fs::exists(dir, ec) && fs::is_directory(dir, ec);
}

std::optional<std::string> ChooseSaveFolderDialog(HWND parent) {
  // The Flutter UI thread is already an STA, but initializing again is
  // safe (S_FALSE) and balanced by CoUninitialize below. RPC_E_CHANGED_MODE
  // means the thread is MTA — proceed without owning the uninit.
  const HRESULT init_hr =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  const bool owns_com = SUCCEEDED(init_hr);

  std::optional<std::string> chosen;

  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(dialog.GetAddressOf()));
  if (SUCCEEDED(hr) && dialog != nullptr) {
    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                       FOS_PATHMUSTEXIST);
    hr = dialog->Show(parent);
    if (SUCCEEDED(hr)) {
      Microsoft::WRL::ComPtr<IShellItem> item;
      if (SUCCEEDED(dialog->GetResult(item.GetAddressOf())) && item != nullptr) {
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) &&
            path != nullptr) {
          chosen = WideToUtf8(std::wstring(path));
          ::CoTaskMemFree(path);
        }
      }
    }
    // A user cancel returns HRESULT_FROM_WIN32(ERROR_CANCELLED); `chosen`
    // simply stays empty, which the bridge reports to Dart as null.
  }

  if (owns_com) {
    ::CoUninitialize();
  }
  return chosen;
}

}  // namespace clingfy::storage
