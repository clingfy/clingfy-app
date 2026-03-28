import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';

class HomeUiPrefs {
  const HomeUiPrefs({
    required this.indicatorPinned,
    required this.targetMode,
    this.paneLayout = const DesktopPaneLayoutPrefs(),
  });

  final bool indicatorPinned;
  final DisplayTargetMode targetMode;
  final DesktopPaneLayoutPrefs paneLayout;
}
