// Step 5.6 — single-instance gate + WM_COPYDATA forwarding.
//
// When the user double-clicks a `.clingfyproj` in Explorer, Windows
// launches a new clingfy.exe with the project path as argv[1]. If a
// clingfy.exe is already running, we want the existing process to pop
// to front and emit `openProjectRequest` rather than starting a second
// app instance. This file is the Win32 plumbing for that handoff:
//
//   1. The first process to start `Acquire`s a named mutex
//      (`Clingfy.SingleInstance.<bundle-id>`) and creates a hidden
//      message-only window registered under a known class name. It
//      then enters its normal Flutter event loop.
//
//   2. A second process notices the mutex is already owned, locates
//      the first process's window via `FindWindowW` on the known
//      class name, and `SendMessage`s WM_COPYDATA carrying the
//      `.clingfyproj` path (UTF-16) as the payload. It exits
//      immediately with EXIT_SUCCESS.
//
//   3. The first process's WindowProc decodes the path and forwards
//      it to `ProjectOpenCoordinator::Enqueue` (UTF-8), which either
//      emits directly (if Dart's workflow listener is attached) or
//      queues until it is.
//
// This matches the macOS `application(_:open:)` AppDelegate
// experience and reuses the same `openProjectRequest` workflow event.
//
// The implementation deliberately avoids more elaborate IPC (named
// pipes / RPC) because the payload is a single short Unicode string
// and `WM_COPYDATA` is Microsoft's documented way to ship that. See
// https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-copydata.
//
// Threading: the receiver window's WindowProc runs on the platform
// thread that called `RegisterReceiver`. Forwarding into the
// `ProjectOpenCoordinator` is thread-safe regardless.

#ifndef RUNNER_CORE_SINGLE_INSTANCE_H_
#define RUNNER_CORE_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

namespace clingfy::core {

// `dwData` value carried on the WM_COPYDATA message so the receiver
// can reject foreign WM_COPYDATA traffic (other apps using the
// primitive happen to land in your message queue too). Arbitrary
// 32-bit constant — chosen as ASCII "CFy1" (0x43467931).
constexpr ULONG_PTR kProjectOpenWmCopyDataId = 0x43467931ULL;

// Class name used for the receiver window. Must be globally unique
// per bundle-id; we suffix in the lookup function below.
constexpr wchar_t kReceiverWindowClass[] = L"ClingfyProjectOpenReceiver";

// Tries to acquire the per-bundle-id single-instance mutex. Returns
// `true` if this is the first / sole instance (the caller should keep
// running). Returns `false` if another instance already owns the
// mutex (the caller is the second-instance and should forward + exit).
//
// `bundle_id_suffix` is appended to the mutex name so the dev build
// (`com.clingfy.clingfy.dev`) and the prod build
// (`com.clingfy.clingfy`) don't gate each other. Empty string falls
// back to a default suffix.
bool TryAcquireInstanceMutex(const std::wstring& bundle_id_suffix);

// Find the receiver window of the existing instance and forward the
// project path to it via WM_COPYDATA. Returns true if the message was
// delivered (SendMessage returned a non-zero result, meaning the
// receiver accepted). False if no receiver window was found or the
// send failed. The bundle_id_suffix MUST match the existing instance's.
bool ForwardProjectPathToExistingInstance(
    const std::wstring& bundle_id_suffix,
    const std::wstring& project_path);

// Register a hidden message-only window that listens for the project-
// open WM_COPYDATA on the platform thread. The window persists for
// the lifetime of the process; the runtime tears it down on app exit.
// On any incoming valid WM_COPYDATA, the received UTF-16 path is
// converted to UTF-8 and forwarded to `ProjectOpenCoordinator::Enqueue`.
//
// Returns true on success, false on RegisterClassExW / CreateWindowExW
// failure. Failure does not abort the app — the missing receiver just
// means we lose the Explorer-reopen feature; the cold-start argv path
// still works.
bool RegisterProjectOpenReceiver(const std::wstring& bundle_id_suffix);

// Stop the receiver window. Called from `FlutterWindow::OnDestroy` or
// at process exit. Idempotent.
void UnregisterProjectOpenReceiver();

// Internal-but-exposed-for-tests: parse a WM_COPYDATA payload back
// into a UTF-16 path. Returns empty wstring on malformed input.
std::wstring DecodeProjectOpenPayload(const COPYDATASTRUCT* data);

// Internal-but-exposed-for-tests: build a COPYDATASTRUCT-compatible
// byte buffer carrying `project_path`. The buffer is owned by the
// caller; pass `.data()` as `lpData` and the returned vector's
// `.size()` as `cbData` when calling `SendMessageW(WM_COPYDATA, ...)`.
std::wstring NormalizeProjectPathPayload(const std::wstring& project_path);

}  // namespace clingfy::core

#endif  // RUNNER_CORE_SINGLE_INSTANCE_H_
