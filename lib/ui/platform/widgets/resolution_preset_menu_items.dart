import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';

List<PlatformMenuItem<ResolutionPreset>> buildResolutionPresetMenuItems(
  AppLocalizations l10n,
) {
  return [
    PlatformMenuItem(value: ResolutionPreset.auto, label: l10n.auto),
    PlatformMenuItem(value: ResolutionPreset.p1080, label: l10n.fhd1080),
    PlatformMenuItem(value: ResolutionPreset.p1440, label: l10n.uhd2k),
    PlatformMenuItem(value: ResolutionPreset.p2160, label: l10n.uhd4k),
    PlatformMenuItem(value: ResolutionPreset.p4320, label: l10n.uhd8k),
  ];
}
