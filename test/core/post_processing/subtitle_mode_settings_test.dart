import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/post_processing/settings/post_processing_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The subtitle destination is a preference, not project state: someone who
/// always burns in for social should not re-pick it every recording.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PostProcessingSettingsController> load(
    Map<String, Object> initial,
  ) async {
    SharedPreferences.setMockInitialValues(initial);
    final controller = PostProcessingSettingsController();
    await controller.loadPreferences(await SharedPreferences.getInstance());
    addTearDown(controller.dispose);
    return controller;
  }

  test('the default destination is burn-in', () async {
    final controller = await load({});
    // The destination that cannot be lost: a sidecar is stripped by most
    // upload paths, and generating subtitles then seeing none in the exported
    // file reads as broken.
    expect(controller.postSubtitleMode, SubtitleMode.burnIn);
  });

  test('a stored destination is restored', () async {
    for (final mode in SubtitleMode.values) {
      final controller = await load({'postSubtitleMode': mode.wireValue});
      expect(controller.postSubtitleMode, mode);
    }
  });

  test('a destination from a newer build falls back to burn-in', () async {
    final controller = await load({'postSubtitleMode': 'holographic'});
    expect(controller.postSubtitleMode, SubtitleMode.burnIn);
  });

  test('updating persists the wire value and notifies once', () async {
    final controller = await load({});
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.updatePostSubtitleMode(SubtitleMode.both);

    expect(notified, 1);
    expect(controller.postSubtitleMode, SubtitleMode.both);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('postSubtitleMode'), 'both');
  });

  test('re-selecting the current destination is a no-op', () async {
    final controller = await load({});
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.updatePostSubtitleMode(SubtitleMode.burnIn);

    expect(notified, 0);
  });

  test('the destination survives a restart', () async {
    final first = await load({});
    await first.updatePostSubtitleMode(SubtitleMode.sidecar);

    // Same backing store, fresh controller — what the next launch sees.
    final second = PostProcessingSettingsController();
    await second.loadPreferences(await SharedPreferences.getInstance());
    addTearDown(second.dispose);

    expect(second.postSubtitleMode, SubtitleMode.sidecar);
  });

  test(
    'turning subtitles off is a real stored choice, not the default',
    () async {
      // `none` must round-trip: falling back to burn-in here would re-enable
      // something the user deliberately switched off.
      final controller = await load({});
      await controller.updatePostSubtitleMode(SubtitleMode.none);

      final reloaded = PostProcessingSettingsController();
      await reloaded.loadPreferences(await SharedPreferences.getInstance());
      addTearDown(reloaded.dispose);

      expect(reloaded.postSubtitleMode, SubtitleMode.none);
    },
  );
}
