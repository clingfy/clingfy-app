import 'package:clingfy/app/bootstrap/app_bootstrap.dart';
import 'package:clingfy/app/debug/poc_stage_2a_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Phase 5 POC Stage 2A-1: debug-only Flutter shell that mounts the
  // texture-bridge screen instead of the production app. The branch
  // collapses to a compile-time constant; production builds inline it
  // out and never touch the POC widget tree.
  if (PocStage2aScreen.isEnabled) {
    runApp(const PocStage2aApp());
    return;
  }
  await AppBootstrap.run();
}
