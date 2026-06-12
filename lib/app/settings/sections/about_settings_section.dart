import 'dart:async';

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/widgets/about_section.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/updater/update_check_events.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutSettingsSection extends StatefulWidget {
  const AboutSettingsSection({super.key});

  @override
  State<AboutSettingsSection> createState() => _AboutSettingsSectionState();
}

class _AboutSettingsSectionState extends State<AboutSettingsSection> {
  PackageInfo? _packageInfo;

  // Phase 10.6 (Windows): the update check reports through the updater
  // event channel; this section renders the honest status inline and pops
  // the update-available dialog for checks the user started here. macOS
  // never reaches this state machine — Sparkle owns the whole flow.
  StreamSubscription<Map<String, dynamic>>? _updaterSubscription;
  UpdateCheckEvent? _updateState;
  bool _checkInFlight = false;

  @override
  void initState() {
    super.initState();
    _initPackageInfo();
    if (isWindows()) {
      _updaterSubscription = NativeBridge.instance.updaterEvents.listen(
        _handleUpdaterEvent,
      );
    }
  }

  @override
  void dispose() {
    _updaterSubscription?.cancel();
    super.dispose();
  }

  void _handleUpdaterEvent(Map<String, dynamic> raw) {
    final event = UpdateCheckEvent.fromMap(raw);
    if (event == null || !mounted) {
      return;
    }
    setState(() {
      _updateState = event;
    });
    if (event.status == UpdateCheckStatus.updateAvailable && _checkInFlight) {
      _checkInFlight = false;
      _showUpdateAvailableDialog(event);
    } else if (event.status != UpdateCheckStatus.checking) {
      _checkInFlight = false;
    }
  }

  Future<void> _checkForUpdatesWindows() async {
    setState(() {
      _checkInFlight = true;
      // Render "checking" immediately; the native `checking` event keeps it.
      _updateState = UpdateCheckEvent.fromMap(const {'type': 'checking'});
    });
    final started = await NativeBridge.instance.checkForUpdates();
    if (!started && mounted) {
      setState(() {
        _checkInFlight = false;
        _updateState = UpdateCheckEvent.fromMap(const {
          'type': 'updateError',
          'code': UpdateCheckErrorCodes.feedNotConfigured,
        });
      });
    }
  }

  Future<void> _openInstallerUrl(String? url) async {
    if (url == null) {
      return;
    }
    final uri = Uri.tryParse(url);
    // The native check already enforces https; re-check here so a future
    // feed regression can never hand the shell a non-https target.
    if (uri == null || uri.scheme != 'https') {
      return;
    }
    await launchUrl(uri);
  }

  void _showUpdateAvailableDialog(UpdateCheckEvent event) {
    final l10n = AppLocalizations.of(context)!;
    final versionLabel = event.versionFull ?? event.version ?? '';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.updateAvailableTitle),
        content: Text(l10n.updateAvailableBody(versionLabel)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.updateLater),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _openInstallerUrl(event.url);
            },
            child: Text(l10n.updateDownload),
          ),
        ],
      ),
    );
  }

  Future<void> _initPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) {
      return;
    }
    setState(() {
      _packageInfo = info;
    });
  }

  Future<void> _launchUrl(String urlString) async {
    final url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final links = <_LinkItem>[
      _LinkItem(
        label: l10n.visitWebsite,
        url: 'https://clingfy.com',
        icon: CupertinoIcons.globe,
      ),
      _LinkItem(
        label: l10n.contactSupport,
        url: 'mailto:contact@clingfy.com',
        icon: CupertinoIcons.mail,
      ),
      _LinkItem(
        label: l10n.privacyPolicy,
        url: 'https://clingfy.com/privacy',
        icon: CupertinoIcons.shield,
      ),
      _LinkItem(
        label: l10n.termsOfService,
        url: 'https://clingfy.com/terms',
        icon: CupertinoIcons.doc_text,
      ),
    ];

    return buildSectionPage(
      context,
      children: [
        SettingsCard(
          title: l10n.aboutThisApp,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                CupertinoIcons.video_camera_solid,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 20),
              AboutSection(packageInfo: _packageInfo),
              const SizedBox(height: 20),
              // Restored on Windows in Phase 10.6: checkForUpdates is the
              // real D2 feed check now (the 10.3 hide existed because it was
              // a hardcoded-false stub). macOS keeps the Sparkle flow, which
              // drives its own dialogs — no inline status there.
              AppButton(
                label: l10n.checkForUpdates,
                icon: CupertinoIcons.arrow_clockwise,
                variant: AppButtonVariant.primary,
                size: AppButtonSize.regular,
                onPressed: isWindows()
                    ? _checkForUpdatesWindows
                    : () => NativeBridge.instance.checkForUpdates(),
              ),
              if (isWindows() && _updateState != null) ...[
                const SizedBox(height: 12),
                _buildUpdateStatus(context, l10n, _updateState!),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.settingsLinks,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = constraints.maxWidth > 560
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: links
                    .map(
                      (link) => SizedBox(
                        width: cardWidth,
                        child: _buildLinkCard(context, link),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildUpdateStatus(
    BuildContext context,
    AppLocalizations l10n,
    UpdateCheckEvent state,
  ) {
    final theme = Theme.of(context);
    switch (state.status) {
      case UpdateCheckStatus.checking:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(l10n.updateChecking, style: theme.textTheme.bodySmall),
          ],
        );
      case UpdateCheckStatus.noUpdateAvailable:
        return Text(
          l10n.updateUpToDate,
          key: const Key('about_update_up_to_date'),
          style: theme.textTheme.bodySmall,
        );
      case UpdateCheckStatus.error:
        return Text(
          l10n.updateCheckFailed,
          key: const Key('about_update_check_failed'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        );
      case UpdateCheckStatus.updateAvailable:
        final versionLabel = state.versionFull ?? state.version ?? '';
        return Column(
          children: [
            Text(
              l10n.updateAvailableBody(versionLabel),
              key: const Key('about_update_available'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            AppButton(
              label: l10n.updateDownload,
              icon: CupertinoIcons.cloud_download,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => _openInstallerUrl(state.url),
            ),
          ],
        );
    }
  }

  Widget _buildLinkCard(BuildContext context, _LinkItem link) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _launchUrl(link.url),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: 0.10),
                theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.75,
                ),
              ],
            ),
            border: Border.all(color: accent.withValues(alpha: 0.14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(link.icon, size: 18, color: accent),
                  ),
                  const Spacer(),
                  Icon(
                    CupertinoIcons.arrow_up_right,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                link.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _linkCaption(link.url),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _linkCaption(String url) {
    final uri = Uri.parse(url);
    if (uri.scheme == 'mailto') {
      return uri.path;
    }
    if (uri.host.isEmpty) {
      return url;
    }
    final path = uri.path == '/' ? '' : uri.path;
    return '${uri.host}$path';
  }
}

class _LinkItem {
  const _LinkItem({required this.label, required this.url, required this.icon});

  final String label;
  final String url;
  final IconData icon;
}
