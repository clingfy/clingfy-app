# Logging

One pipeline, one format, one file — on every platform.

```
Dart   Log.d/i/w/e ─────────────────────────────┐
macOS  NativeLogger.d/i/w/e ──▶ channel "log" ──┤──▶ Log._processEvent
Windows NativeLogPublisher::Debug/Info/Warn/Error┘         │
                                                ┌──────────┼──────────┐
                                                ▼          ▼          ▼
                                          debug console  FileLogSink  RemoteLogSink
                                          (debug builds) JSONL daily  (Sentry today)
```

The Dart `Log` class (`lib/core/logging/logger_service.dart`) is the single
sink owner. Both native sides are pure producers: they never write their own
log files; every line crosses the method channel as a reverse `log` call and
lands in the same JSONL file and the same remote sink.

## The line format (JSONL)

One JSON object per line in
`<application-support>/Logs/logs_YYYY-MM-DD.jsonl` (local-date file name,
30-day retention, daily rollover):

| Key | Always | Meaning |
|---|---|---|
| `ts` | ✓ | UTC ISO8601 with fractional seconds and a trailing `Z` — one clock base for every origin |
| `level` | ✓ | `DEBUG` `INFO` `WARNING` `ERROR` |
| `origin` | ✓ | `flutter` \| `native` |
| `category` | ✓ | subsystem tag (`Recording`, `Preview`, `DeviceProbe`, …) |
| `message` | ✓ | human-readable line |
| `sessionId` | ✓ | stamped at Dart ingest (UTC ISO of app launch) |
| `file` / `line` | — | producer source location (macOS sends it for free via `#file`/`#line`) |
| `recordingId` | — | present while a recording session is active |
| `context` | — | structured key/values; omitted when empty |
| `error` / `stack` | — | failure text / trace; drives the Sentry native-ERROR exception promotion |

Absent fields are **omitted**, never `null`. The native `context['error']` /
`context['stack']` convention is promoted to the top-level fields at Dart
ingest when the payload didn't set them.

## Levels and gating

Every producer gates **at the source** — a below-threshold line never crosses
the channel and never reaches the file/Sentry:

- Default threshold: `debug` in debug builds, `info` in release/profile.
- `CLINGFY_LOG_LEVEL` env var overrides the default on **all three sides**
  (useful for capturing verbose logs from a release build, e.g. the stress
  harness).
- The Settings **"verbose logging"** toggle switches the Dart threshold
  (`Log.setVerbose`) and pushes the level to native via `setNativeLogLevel`
  → macOS `NativeLogger.setMinLevel` / Windows
  `NativeLogPublisher::SetMinLevel`.

Level guidance: `Debug` = per-feature tracing and lifecycle breadcrumbs
(device probes, preview engine steps); `Info` = coarse user-visible lifecycle;
`Warning` = degradations the app survived; `Error` = real failures — on
native, pass the failure text as `error` (or `context['error']`) so Sentry
promotes it to a grouped exception.

## Startup: nothing is dropped

Logs emitted before the pipeline is ready are buffered, bounded (512,
drop-oldest), and replayed in order:

- **Dart before `Log.init`** → in-memory pre-init buffer, drained by `init`.
- **Native before the channel/handler exists** → pending buffer inside
  `NativeLogger` / `NativeLogPublisher`. When Dart's `NativeBridge` installs
  its `log` handler it fires `flushPendingNativeLogs` (fire-and-forget), and
  native drains the buffer through the channel. This is why startup device
  enumeration and the recovery sweep show up in the file.

## Adding a remote/third-party logging service

Implement `RemoteLogSink` (`logger_service.dart`) and pass it to
`Log.init(remoteSink: …)` (wired in `lib/app/bootstrap/app_runner.dart` /
`sentry_setup.dart`). Every event from every origin flows through
`send(LogEvent)` — producers never need to change. `ClingfyTelemetry`
(Sentry) is the reference implementation: breadcrumb per event, exception
promotion for native ERRORs.

## What is deliberately NOT in the pipeline

- `phase5_cycles.log` + `stage2a_2_result.md`
  (`%LOCALAPPDATA%\Clingfy\Logs`) — Windows stress-harness **measurement
  artifacts** consumed by `tools/phase5_*.ps1`; data files, not logs.
- Sentry crash capture (crashpad / sentry-cocoa minidumps) — crash-time
  forensics, owned by `sentry_flutter`.
- `debugPrint` inside `lib/core/logging/` itself — the sink cannot log
  through the logger it implements (recursion); these are meta-errors only.

## Retired mechanisms (do not reintroduce)

- Windows `device_probe.log` side file → `LogDeviceProbe` now forwards to
  `NativeLogPublisher::Debug("DeviceProbe", …)`.
- Windows `stage2a_2_native.log` crash-breadcrumb file → `LogNative` in
  `preview_engine.cpp` forwards to `Debug("Preview", …)`; run with
  `CLINGFY_LOG_LEVEL=debug` to capture the same breadcrumbs in the JSONL.
- Timezone-naive local timestamps from Dart (`toIso8601String()` without
  `toUtc()`) — everything is UTC `Z` now.

## Contract tests (keep the three in sync)

- Dart: `test/core/logging/logger_format_contract_test.dart`
- Windows: `windows/runner_tests/native_log_publisher_test.cpp`
- macOS: `NativeLoggerTests` in `macos/RunnerTests/RunnerTests.swift`

If you change the payload shape, update all three plus the parser
(`Log.parseNativeEvent`) and this document.
