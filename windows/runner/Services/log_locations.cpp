#include "Services/log_locations.h"

#include <shlobj.h>
#include <windows.h>

#include <cstdio>
#include <ctime>
#include <vector>

namespace clingfy::storage {

namespace {

std::wstring ReadEnv(const wchar_t* name) {
  const DWORD needed = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (needed <= 1) {
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

std::wstring KnownFolder(REFKNOWNFOLDERID id, const wchar_t* env_fallback) {
  PWSTR raw = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(id, 0, nullptr, &raw)) &&
      raw != nullptr) {
    std::wstring path(raw);
    ::CoTaskMemFree(raw);
    if (!path.empty()) {
      return path;
    }
  } else if (raw != nullptr) {
    ::CoTaskMemFree(raw);
  }
  return ReadEnv(env_fallback);
}

// Read a single string field ("CompanyName"/"ProductName") from this exe's
// version resource — the same source path_provider's Windows implementation
// uses to build the application-support directory.
std::wstring VersionResourceString(const wchar_t* field) {
  wchar_t exe_path[MAX_PATH] = {};
  const DWORD len = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return {};
  }
  const DWORD info_size = ::GetFileVersionInfoSizeW(exe_path, nullptr);
  if (info_size == 0) {
    return {};
  }
  std::vector<unsigned char> info(info_size);
  if (!::GetFileVersionInfoW(exe_path, 0, info_size, info.data())) {
    return {};
  }
  // Enumerate the available translations and take the first — Runner.rc
  // declares exactly one (US English / Unicode).
  struct LangCodePage {
    WORD language;
    WORD code_page;
  };
  LangCodePage* translations = nullptr;
  UINT translations_bytes = 0;
  if (!::VerQueryValueW(info.data(), L"\\VarFileInfo\\Translation",
                        reinterpret_cast<void**>(&translations),
                        &translations_bytes) ||
      translations == nullptr || translations_bytes < sizeof(LangCodePage)) {
    return {};
  }
  wchar_t query[64] = {};
  std::swprintf(query, 64, L"\\StringFileInfo\\%04x%04x\\%s",
                translations[0].language, translations[0].code_page, field);
  wchar_t* value = nullptr;
  UINT value_chars = 0;
  if (!::VerQueryValueW(info.data(), query, reinterpret_cast<void**>(&value),
                        &value_chars) ||
      value == nullptr || value_chars == 0) {
    return {};
  }
  // value_chars includes the terminating null.
  return std::wstring(value, value + value_chars - 1);
}

}  // namespace

std::wstring JoinNativeLogsDir(const std::wstring& local_app_data) {
  if (local_app_data.empty()) {
    return {};
  }
  return local_app_data + L"\\Clingfy\\Logs";
}

std::wstring JoinDartLogsDir(const std::wstring& roaming_app_data,
                             const std::wstring& company,
                             const std::wstring& product) {
  if (roaming_app_data.empty() || company.empty() || product.empty()) {
    return {};
  }
  return roaming_app_data + L"\\" + company + L"\\" + product + L"\\Logs";
}

std::wstring DartLogFileNameForDate(int year, int month, int day) {
  wchar_t name[32] = {};
  std::swprintf(name, 32, L"logs_%04d-%02d-%02d.jsonl", year, month, day);
  return name;
}

std::wstring NativeLogsDirectory() {
  const std::wstring override_dir = ReadEnv(L"CLINGFY_NATIVE_LOG_DIR");
  if (!override_dir.empty()) {
    return override_dir;
  }
  // Function-local static: resolved once, thread-safe under C++11 init.
  static const std::wstring resolved = JoinNativeLogsDir(
      KnownFolder(FOLDERID_LocalAppData, L"LOCALAPPDATA"));
  return resolved;
}

std::wstring DartLogsDirectory() {
  // Test/support override, checked on every call (mirrors
  // CLINGFY_NATIVE_LOG_DIR) so the cached Known Folder result below never
  // poisons an overridden run.
  const std::wstring override_dir = ReadEnv(L"CLINGFY_DART_LOG_DIR");
  if (!override_dir.empty()) {
    return override_dir;
  }
  static const std::wstring resolved = [] {
    std::wstring company = VersionResourceString(L"CompanyName");
    std::wstring product = VersionResourceString(L"ProductName");
    if (company.empty()) {
      company = L"com.clingfy";  // Runner.rc fallback
    }
    if (product.empty()) {
      product = L"clingfy";  // Runner.rc fallback
    }
    return JoinDartLogsDir(KnownFolder(FOLDERID_RoamingAppData, L"APPDATA"),
                           company, product);
  }();
  return resolved;
}

std::wstring TodayDartLogFilePath() {
  const std::wstring dir = DartLogsDirectory();
  if (dir.empty()) {
    return {};
  }
  // Local date — FileLogSink stamps with the local clock.
  std::time_t now = std::time(nullptr);
  std::tm tm_local{};
#if defined(_MSC_VER)
  ::localtime_s(&tm_local, &now);
#else
  tm_local = *std::localtime(&now);
#endif
  return dir + L"\\" +
         DartLogFileNameForDate(tm_local.tm_year + 1900, tm_local.tm_mon + 1,
                                tm_local.tm_mday);
}

}  // namespace clingfy::storage
