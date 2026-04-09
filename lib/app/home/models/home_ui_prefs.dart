import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';

const kDefaultHomePaneLayoutPrefs = DesktopPaneLayoutPrefs(
  paneStates: {
    DesktopPaneId.homeLeftSidebar: DesktopPaneState(isCollapsed: true),
  },
);

class HomeUiPrefs {
  const HomeUiPrefs({
    required this.indicatorPinned,
    required this.targetMode,
    this.paneLayout = kDefaultHomePaneLayoutPrefs,
  });

  final bool indicatorPinned;
  final DisplayTargetMode targetMode;
  final DesktopPaneLayoutPrefs paneLayout;
}
