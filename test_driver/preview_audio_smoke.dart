// On-device driver smoke for editing 4-7 (preview audio).
//
// Drives Play/Pause on a stitched (edited) timeline in a RUNNING debug build
// and prints the transport clock, so the caller can assert the audio-mastered
// position advances in real time, freezes exactly on pause, resumes, and pins
// at the timeline end instead of running past it (the 4-7b review's critical
// EOS bug would show here as a clock that never stops).
//
// Usage:
//   1. flutter run -d windows --dart-define-from-file=.env.dev \
//        --dart-define=ENABLE_FLUTTER_DRIVER=true
//   2. Open a project whose clips_state.json holds a real edit (a cut or
//      reorder), so the preview is in stitched mode.
//   3. dart run test_driver/preview_audio_smoke.dart <ws-vm-service-url>
//      (the ws://127.0.0.1:<port>/<token>/ws URL that flutter run printed)
// The clock printout IS this harness's interface — the caller reads stdout.
// ignore_for_file: avoid_print
import 'package:flutter_driver/flutter_driver.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'pass the running app\'s VM service websocket URL '
      '(ws://127.0.0.1:<port>/<token>/ws — printed by flutter run)',
    );
  }
  final driver = await FlutterDriver.connect(
    dartVmServiceUrl: args[0],
    printCommunication: false,
  );
  final play = find.byValueKey('timeline_play_pause_button');
  final time = find.byValueKey('timeline_transport_time');
  try {
    await driver.waitFor(play, timeout: const Duration(seconds: 15));
    print('TIME_BEFORE=${await driver.getText(time)}');
    await driver.tap(play);
    await Future<void>.delayed(const Duration(seconds: 4));
    print('TIME_MID=${await driver.getText(time)}');
    await Future<void>.delayed(const Duration(seconds: 3));
    print('TIME_LATE=${await driver.getText(time)}');
    await driver.tap(play); // pause
    await Future<void>.delayed(const Duration(seconds: 1));
    final paused = await driver.getText(time);
    print('TIME_PAUSED=$paused');
    await Future<void>.delayed(const Duration(seconds: 2));
    print('TIME_PAUSED_LATER=${await driver.getText(time)}');
    await driver.tap(play); // resume — should play out to the 0:12 end
    await Future<void>.delayed(const Duration(seconds: 8));
    print('TIME_AT_END=${await driver.getText(time)}');
  } finally {
    await driver.close();
  }
}
