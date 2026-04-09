import 'package:clingfy/ui/theme/app_shell_tokens.dart';

abstract final class HomeDesktopPaneDimensions {
  static const double railWidth = 208;
  static const double compactRailWidth = 68;
  static const double inspectorDefault = 332;
  static const double inspectorMin = 280;
  static const double inspectorMax = 420;
  static const double inspectorCollapsed = 0;
  static const double workspaceMinWidth = 760;
  static const double workspaceMinHeight = 520;
  static const double shellMinHeight = 592;
  static const double outerGap = kEditorShellGap;
  static const double innerGap = kEditorShellGap;
  static const double inspectorAutoHideThreshold =
      railWidth + outerGap + inspectorMin + innerGap + workspaceMinWidth;

  static const double innerExpandedMinWidth =
      inspectorMin + innerGap + workspaceMinWidth;
  static const double innerCollapsedMinWidth = workspaceMinWidth;
  static const double shellMinWidth =
      compactRailWidth + outerGap + innerCollapsedMinWidth;
}
