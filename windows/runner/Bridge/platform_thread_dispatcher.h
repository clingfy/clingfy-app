#ifndef RUNNER_BRIDGE_PLATFORM_THREAD_DISPATCHER_H_
#define RUNNER_BRIDGE_PLATFORM_THREAD_DISPATCHER_H_

#include <windows.h>

#include <functional>

// Marshals arbitrary callbacks back to the Flutter platform thread.
//
// Step 5.4 of the Phase 5 implementation plan emitted player/events
// (`playerTick`, `playerState`, `playerError`, `playerWarning`)
// directly from MediaPlayer worker threads and from a producer
// heartbeat thread. Flutter's platform-channel contract requires that
// every `EventSink::Success()` / `MethodResult::Success()` call land
// on the platform thread (the same thread that runs the engine's
// message loop) — calling from any other thread triggers the
// "channel sent a message from native to Flutter on a non-platform
// thread" warning and risks crashes / out-of-order delivery.
//
// This dispatcher is the marshaling primitive every component that
// needs to talk back to Flutter from a non-platform thread routes
// through. The pattern is standard for Windows host applications:
//
//   * A single hidden message-only window (HWND_MESSAGE parent) is
//     created on the platform thread.
//   * Any thread can call Post() — it heap-allocates the callable and
//     issues a `PostMessage(WM_APP+1)`.
//   * The window's WindowProc runs on the platform thread (because
//     PostMessage is delivered to the thread that created the window
//     and processes its message loop). It invokes the callable, then
//     deletes the heap allocation.
//
// The dispatcher is a singleton. Initialize() must be called once at
// FlutterWindow setup, BEFORE EventChannelStubs registers any
// channels — that way every Emit* path can rely on the dispatcher
// being available. After Initialize() succeeds, Post() is safe from
// any thread for the life of the process. There is intentionally no
// Shutdown() — the message-only window outlives the process; the OS
// reclaims at exit.

namespace clingfy::bridge {

class PlatformThreadDispatcher {
 public:
  static PlatformThreadDispatcher& Instance();

  PlatformThreadDispatcher(const PlatformThreadDispatcher&) = delete;
  PlatformThreadDispatcher& operator=(const PlatformThreadDispatcher&) = delete;

  // Register the window class + create the hidden message-only
  // window. Must be called on the platform thread (the thread the
  // engine's message loop runs on). Subsequent calls are no-ops.
  // Returns true when the dispatcher is ready to Post; false when
  // the window class / window could not be created (in which case
  // is_initialized() returns false and Post() falls back to a no-op).
  bool Initialize();

  // True once Initialize() succeeded. Lets callers decide between the
  // platform-thread path (when true) and an immediate-call fallback
  // (when false — typically only during tests or before FlutterWindow
  // has finished startup).
  bool is_initialized() const { return hwnd_ != nullptr; }

  // Post a callback to be executed on the platform thread. Safe from
  // any thread.
  //
  //   * If the dispatcher hasn't been initialized, the task runs
  //     immediately on the calling thread. This is the test-time
  //     behaviour and is what existing publisher unit tests rely on.
  //   * If PostMessage fails (e.g. queue is full, ~10,000 entries
  //     max on Windows), the task runs immediately on the calling
  //     thread as a defensive fallback — better a slightly-wrong
  //     thread than a dropped event.
  void Post(std::function<void()> task);

  // Post WITHOUT the two inline fallbacks above. Returns true only when the
  // task was actually queued for the platform thread; returns false (dropping
  // the task) when the dispatcher is uninitialized or PostMessage fails.
  //
  // Post()'s "better a slightly-wrong thread than a dropped event" trade is the
  // right default for notifications, but it is unsafe for a task that must not
  // run on the caller's thread. The camera overlay's park notification is the
  // motivating case: it fires on the DComp presenter's own overlay thread, and
  // the work it schedules calls that presenter's Stop(), which joins that same
  // thread — inline execution would self-join and throw
  // resource_deadlock_would_occur. Note both inline paths matter: the
  // PostMessage-failure one is reachable in production, and its likeliest cause
  // (a saturated queue on a struggling machine) correlates with the wedged-GPU
  // condition that produces the park in the first place.
  //
  // Callers must therefore treat `false` as "not delivered" and stay correct
  // without it.
  bool TryPost(std::function<void()> task);

 private:
  PlatformThreadDispatcher() = default;

  // Window procedure for the hidden message-only window. Receives
  // `WM_APP + 1` messages whose `lparam` is a heap-allocated
  // `std::function<void()>*`. Invokes the function, then deletes it.
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                                     LPARAM lparam);

  HWND hwnd_ = nullptr;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_PLATFORM_THREAD_DISPATCHER_H_
