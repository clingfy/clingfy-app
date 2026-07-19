// Scratch driver smoke for editing 4-7 (preview audio) — NOT committed.
// Connects to a running debug build (ENABLE_FLUTTER_DRIVER=true) that has the
// smoke-preview-audio.clingfyproj open, drives Play/Pause on the stitched
// timeline, and prints the transport clock so the caller can assert that the
// audio-mastered position advances, freezes on pause, and pins at the end.
import 'package:flutter_driver/flutter_driver.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty
      ? args[0]
      : 'ws://127.0.0.1:53595/T_io8nWnOac=/ws';
  final driver = await FlutterDriver.connect(
    dartVmServiceUrl: url,
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
