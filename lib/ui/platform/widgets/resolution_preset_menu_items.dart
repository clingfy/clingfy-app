import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';

List<PlatformMenuItem<ResolutionPreset>> buildResolutionPresetMenuItems(
  AppLocalizations l10n,
) {
  return [
    PlatformMenuItem(value: ResolutionPreset.auto, label: l10n.auto),
    const PlatformMenuItem(value: ResolutionPreset.p1080, label: '1080p'),
    const PlatformMenuItem(value: ResolutionPreset.p1440, label: '1440p (2K)'),
    const PlatformMenuItem(value: ResolutionPreset.p2160, label: '2160p (4K)'),
    const PlatformMenuItem(value: ResolutionPreset.p4320, label: '4320p (8K)'),
  ];
}
