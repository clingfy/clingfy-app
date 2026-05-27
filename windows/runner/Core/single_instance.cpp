#include "Core/single_instance.h"

#include <windows.h>

#include <atomic>
#include <cstring>
#include <string>

#include "Bridge/project_open_coordinator.h"
#include "Core/argv_project_path.h"

namespace clingfy::core {

namespace {

// Process-wide handle for the receiver window + the named mutex.
// Kept in an anonymous namespace because the runner is single-threaded
// for these lifecycle calls (main thread for Try/Forward/Register;
// WM_DESTROY on the platform thread for Unregister).
HANDLE g_instance_mutex = nullptr;
HWND g_receiver_window = nullptr;
ATOM g_receiver_class = 0;
std::atomic<bool> g_receiver_class_registered{false};

std::wstring MakeMutexName(const std::wstring& bundle_id_suffix) {
  // Use the Local\ namespace so we gate per-session (matches the macOS
  // gotcha — each user session has its own "instance"). Global\ would
  // gate across all sessions which is wrong for a desktop app.
  std::wstring name = L"Local\\Clingfy.SingleInstance.";
  name += bundle_id_suffix.empty() ? L"default" : bundle_id_suffix;
  return name;
}

std::wstring MakeReceiverClassName(const std::wstring& bundle_id_suffix) {
  std::wstring name = kReceiverWindowClass;
  name.push_back(L'.');
  name += bundle_id_suffix.empty() ? L"default" : bundle_id_suffix;
  return name;
}

LRESULT CALLBACK ReceiverWindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                                    LPARAM lparam) {
  if (msg == WM_COPYDATA) {
    const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (cds == nullptr || cds->dwData != kProjectOpenWmCopyDataId) {
      // Not addressed to us; let other handlers see it.
      return FALSE;
    }
    const std::wstring path = DecodeProjectOpenPayload(cds);
    if (!path.empty()) {
      const std::string utf8 = WideToUtf8(path);
      if (!utf8.empty()) {
        bridge::ProjectOpenCoordinator::Instance().Enqueue(utf8);
      }
    }
    // Returning TRUE tells the sender we accepted (the sender used
    // SendMessage, so this value comes back to it). Match the
    // WM_COPYDATA contract: non-zero == accepted.
    return TRUE;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

}  // namespace

bool TryAcquireInstanceMutex(const std::wstring& bundle_id_suffix) {
  if (g_instance_mutex != nullptr) {
    // Already acquired earlier in this process. Treat as "first
    // instance" for the caller — re-entrance is benign.
    return true;
  }
  const std::wstring name = MakeMutexName(bundle_id_suffix);
  // CreateMutexW succeeds in both the first-owner and
  // already-exists cases. GetLastError disambiguates.
  HANDLE handle = ::CreateMutexW(nullptr, FALSE, name.c_str());
  if (handle == nullptr) {
    // Mutex couldn't be created at all (rare; usually low-resource).
    // Treat as "first instance" so we don't accidentally exit on a
    // fluke — the user is better served by a running app than a
    // silent process death.
    return true;
  }
  const DWORD err = ::GetLastError();
  if (err == ERROR_ALREADY_EXISTS) {
    // Someone else owns it. Drop the handle and signal the caller
    // we're the second instance.
    ::CloseHandle(handle);
    return false;
  }
  g_instance_mutex = handle;
  return true;
}

bool ForwardProjectPathToExistingInstance(
    const std::wstring& bundle_id_suffix,
    const std::wstring& project_path) {
  if (project_path.empty()) return false;
  const std::wstring class_name = MakeReceiverClassName(bundle_id_suffix);
  HWND target = ::FindWindowW(class_name.c_str(), nullptr);
  if (target == nullptr) {
    // No receiver — either the first instance is still warming up, or
    // single-instance gating is misconfigured. Caller decides whether
    // to retry or give up.
    return false;
  }
  const std::wstring normalized = NormalizeProjectPathPayload(project_path);
  COPYDATASTRUCT cds{};
  cds.dwData = kProjectOpenWmCopyDataId;
  // cbData is in bytes, including the trailing null we explicitly
  // include for receiver-side parsing safety.
  cds.cbData = static_cast<DWORD>((normalized.size() + 1) * sizeof(wchar_t));
  cds.lpData = const_cast<wchar_t*>(normalized.c_str());

  const LRESULT rc = ::SendMessageW(target, WM_COPYDATA,
                                    reinterpret_cast<WPARAM>(nullptr),
                                    reinterpret_cast<LPARAM>(&cds));
  return rc != 0;
}

bool RegisterProjectOpenReceiver(const std::wstring& bundle_id_suffix) {
  if (g_receiver_window != nullptr) return true;

  const std::wstring class_name = MakeReceiverClassName(bundle_id_suffix);
  HINSTANCE hinst = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = ReceiverWindowProc;
  wc.hInstance = hinst;
  wc.lpszClassName = class_name.c_str();
  // Class-registration is one-shot per atom; tolerate prior runs in
  // the same process by checking ERROR_CLASS_ALREADY_EXISTS.
  g_receiver_class = ::RegisterClassExW(&wc);
  if (g_receiver_class == 0 &&
      ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }
  g_receiver_class_registered.store(true);

  // HWND_MESSAGE makes the window invisible / non-top-level / receives
  // only the messages we care about. Perfect for IPC plumbing.
  g_receiver_window = ::CreateWindowExW(
      0, class_name.c_str(), L"ClingfyProjectOpenReceiver", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, hinst, nullptr);
  return g_receiver_window != nullptr;
}

void UnregisterProjectOpenReceiver() {
  if (g_receiver_window != nullptr) {
    ::DestroyWindow(g_receiver_window);
    g_receiver_window = nullptr;
  }
  // Class atoms are process-lifetime; UnregisterClassW only succeeds
  // if no instances remain, so skip on shutdown — Windows will reap
  // it on process exit.
  if (g_instance_mutex != nullptr) {
    ::CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
  }
}

std::wstring DecodeProjectOpenPayload(const COPYDATASTRUCT* data) {
  if (data == nullptr || data->dwData != kProjectOpenWmCopyDataId) {
    return {};
  }
  if (data->lpData == nullptr || data->cbData == 0) return {};
  // Length validation: cbData must be a positive multiple of
  // sizeof(wchar_t) and the payload must contain a final L'\0'. We
  // are tolerant of cbData under- or over-stating by one wchar (some
  // senders include the null, some don't); always trim at the first
  // explicit L'\0' we find.
  const size_t wide_count = data->cbData / sizeof(wchar_t);
  if (wide_count == 0) return {};
  const auto* src = static_cast<const wchar_t*>(data->lpData);
  // Bounded strnlen for wchar_t — std::wcslen would walk past the
  // bytes if no null was present.
  size_t real_len = 0;
  while (real_len < wide_count && src[real_len] != L'\0') ++real_len;
  return std::wstring(src, real_len);
}

std::wstring NormalizeProjectPathPayload(const std::wstring& project_path) {
  // No-op normalization today — kept as a hook so callers consistently
  // route through here in case a future change needs to canonicalize
  // long-path / UNC / case before transit.
  return project_path;
}

}  // namespace clingfy::core
