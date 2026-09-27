#ifndef RUNNER_CAPTURE_MICROPHONE_MONITOR_SYNC_H_
#define RUNNER_CAPTURE_MICROPHONE_MONITOR_SYNC_H_

// One reconcile hook for the pre-recording microphone meter.
//
// The monitor's correct state is a function of two things that live in two
// places -- the selected input (`WindowsSelectionState`) and whether a
// recording is in flight (`RecordingEngine`) -- and it is changed from three
// directions: the user picking a device, a recording starting, a recording
// ending by any route. Rather than teach each of those what the other two
// are doing, every one of them calls this and it works the answer out from
// current state.
//
// That also makes it order-insensitive, which matters because it is
// asynchronous: two reconciles racing converge on the same answer instead of
// depending on which landed last.
namespace clingfy::capture {

// Bring the monitor in line with the current selection, given whether a
// recording is in flight.
//
// Safe from any thread, and specifically safe to call while holding
// `RecordingEngine::mutex_`: the work is marshalled to the platform thread,
// so nothing here opens a WASAPI endpoint or joins a thread under the
// engine's lock. That is not a theoretical concern in this codebase -- the
// CI hang fixed in #532 was exactly this shape.
//
// `recording` is passed IN rather than read back from the engine, and that
// is the whole reason this is safe. Asking `RecordingEngine::IsSessionActive`
// from the marshalled task would take the engine's mutex on the platform
// thread -- and the teardown call site holds that mutex across an encoder
// finalize, so the UI would sit frozen for the length of it. Every caller
// already knows the answer for certain: a start is recording, a teardown is
// not, and the router can ask before it posts.
void SyncMicrophoneLevelMonitor(bool recording);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_MICROPHONE_MONITOR_SYNC_H_
