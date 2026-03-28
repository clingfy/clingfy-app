import 'package:clingfy/ui/theme/app_shell_tokens.dart';

abstract final class HomeDesktopPaneDimensions {
  static const double railWidth = 60;
  static const double compactRailWidth = 52;
  static const double inspectorDefault = 348;
  static const double inspectorMin = 300;
  static const double inspectorMax = 420;
  static const double inspectorCollapsed = 32;
  static const double workspaceMinWidth = 760;
  static const double workspaceMinHeight = 520;
  static const double shellMinHeight = 592;
  static const double outerGap = kEditorShellGap;
  static const double innerGap = kEditorShellGap;

  static const double innerExpandedMinWidth =
      inspectorMin + innerGap + workspaceMinWidth;
  static const double innerCollapsedMinWidth =
      inspectorCollapsed + innerGap + workspaceMinWidth;
  static const double autoCompactThreshold =
      railWidth + outerGap + innerExpandedMinWidth;
  static const double shellMinWidth =
      compactRailWidth + outerGap + innerCollapsedMinWidth;
}
