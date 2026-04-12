import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel screenRecorderChannel = MethodChannel(
  NativeChannel.screenRecorder,
);
const MethodChannel screenRecorderEventsChannel = MethodChannel(
  NativeChannel.screenRecorderEvents,
);
const MethodChannel playerEventsChannel = MethodChannel(
  NativeChannel.playerEvents,
);
const MethodChannel workflowEventsChannel = MethodChannel(
  NativeChannel.workflowEvents,
);
const MethodChannel updaterEventsChannel = MethodChannel(
  NativeChannel.updaterEvents,
);
const MethodChannel packageInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/package_info',
);

Future<void> installCommonNativeMocks({
  bool screenRecordingGranted = true,
  bool onboardingSeen = true,
  bool homeGuideSeen = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'onboarding_seen_v1': onboardingSeen,
    HomePrefsStore.homeGuidanceSeenKey: homeGuideSeen,
  });

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(packageInfoChannel, (call) async {
    if (call.method == 'getAll') {
      return <String, dynamic>{
        'appName': 'Clingfy',
        'packageName': 'com.clingfy.app',
        'version': '1.2.0',
        'buildNumber': '120',
        'buildSignature': '',
      };
    }
    return null;
  });

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    switch (call.method) {
      case 'getPermissionStatus':
        return <String, bool>{
          'screenRecording': screenRecordingGranted,
          'microphone': false,
          'camera': false,
          'accessibility': false,
        };
      case 'getAudioSources':
      case 'getVideoSources':
      case 'getDisplays':
      case 'getAppWindows':
        return <dynamic>[];
      case 'getStorageSnapshot':
        return <String, dynamic>{
          'systemTotalBytes': 500 * 1024 * 1024 * 1024,
          'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
          'recordingsBytes': 4 * 1024 * 1024,
          'tempBytes': 2 * 1024 * 1024,
          'logsBytes': 512 * 1024,
          'recordingsPath': '/tmp/Clingfy/Recordings',
          'tempPath': '/tmp/Clingfy/Temp',
          'logsPath': '/tmp/Clingfy/Logs',
          'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
          'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
        };
      case 'setAppWindowTarget':
      case 'setAudioSource':
      case 'setVideoSource':
      case 'setRecordingIndicatorPinned':
      case 'setDisplayTargetMode':
      case 'setPreRecordingBarEnabled':
      case 'setPreRecordingBarVisible':
      case 'togglePreRecordingBar':
      case 'setExcludeRecorderApp':
      case 'setExcludeMicFromSystemAudio':
      case 'setCursorHighlightEnabled':
      case 'setCursorHighlightLinkedToRecording':
      case 'setOverlayEnabled':
      case 'setCameraOverlayShape':
      case 'setCameraOverlaySize':
      case 'setCameraOverlayShadow':
      case 'setCameraOverlayBorder':
      case 'setCameraOverlayBorderWidth':
      case 'setCameraOverlayBorderColor':
      case 'setCameraOverlayRoundness':
      case 'setCameraOverlayOpacity':
      case 'setOverlayMirror':
      case 'setChromaKeyEnabled':
      case 'setChromaKeyStrength':
      case 'setChromaKeyColor':
      case 'setCameraOverlayHighlightStrength':
      case 'setCameraOverlayPosition':
      case 'setCameraOverlayCustomPosition':
      case 'setOverlayLinkedToRecording':
      case 'setFileNameTemplate':
      case 'cacheLocalizedStrings':
      case 'startRecording':
      case 'stopRecording':
      case 'pauseRecording':
      case 'resumeRecording':
      case 'togglePauseRecording':
      case 'requestScreenRecordingPermission':
      case 'requestMicrophonePermission':
      case 'requestCameraPermission':
      case 'openAccessibilitySettings':
      case 'openScreenRecordingSettings':
      case 'openSystemSettings':
      case 'revealRecordingsFolder':
      case 'revealTempFolder':
      case 'clearCachedRecordings':
      case 'setAudioMix':
      case 'previewOpen':
      case 'previewClose':
      case 'previewPlay':
      case 'previewPause':
      case 'previewSeekTo':
      case 'previewPeekTo':
      case 'inlinePreviewStop':
      case 'checkForUpdates':
        return null;
      case 'getRecordingCapabilities':
        return <String, dynamic>{
          'canPauseResume': true,
          'backend': 'avfoundation',
          'strategy': 'av_file_output',
        };
      case 'getExcludeRecorderApp':
        return false;
      case 'getExcludeMicFromSystemAudio':
        return true;
      default:
        return null;
    }
  });

  for (final channel in [
    screenRecorderEventsChannel,
    playerEventsChannel,
    workflowEventsChannel,
    updaterEventsChannel,
  ]) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen' || call.method == 'cancel') {
        return null;
      }
      return null;
    });
  }
}

Future<void> clearCommonNativeMocks() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final channel in [
    packageInfoChannel,
    screenRecorderChannel,
    screenRecorderEventsChannel,
    playerEventsChannel,
    workflowEventsChannel,
    updaterEventsChannel,
  ]) {
    messenger.setMockMethodCallHandler(channel, null);
  }
}
