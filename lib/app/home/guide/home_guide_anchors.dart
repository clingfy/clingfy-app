import 'package:clingfy/app/home/guide/home_guide_step.dart';
import 'package:flutter/widgets.dart';

class HomeGuideAnchors {
  final sidebarShell = GlobalKey(debugLabel: 'homeGuideSidebarShell');
  final captureSourceSection = GlobalKey(debugLabel: 'homeGuideCaptureSource');
  final cameraSection = GlobalKey(debugLabel: 'homeGuideCamera');
  final outputSection = GlobalKey(debugLabel: 'homeGuideOutput');
  final startRecordingButton = GlobalKey(debugLabel: 'homeGuideStartRecording');
  final helpButton = GlobalKey(debugLabel: 'homeGuideHelpButton');

  GlobalKey keyForStep(HomeGuideStep step) {
    return switch (step) {
      HomeGuideStep.sidebar => sidebarShell,
      HomeGuideStep.captureSource => captureSourceSection,
      HomeGuideStep.camera => cameraSection,
      HomeGuideStep.output => outputSection,
      HomeGuideStep.startRecording => startRecordingButton,
      HomeGuideStep.help => helpButton,
    };
  }
}
