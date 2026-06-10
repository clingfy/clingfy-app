import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/widgets/about_section.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
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

  @override
  void initState() {
    super.initState();
    _initPackageInfo();
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
              // Phase 10.3 honesty: the Windows updater lands in Phase 10.6
              // (checkForUpdates is a hardcoded-false stub until then) — a
              // button that silently does nothing is worse than no button.
              if (!isWindows())
                AppButton(
                  label: l10n.checkForUpdates,
                  icon: CupertinoIcons.arrow_clockwise,
                  variant: AppButtonVariant.primary,
                  size: AppButtonSize.regular,
                  onPressed: () => NativeBridge.instance.checkForUpdates(),
                ),
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
