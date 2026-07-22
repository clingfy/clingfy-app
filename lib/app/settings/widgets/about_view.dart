import 'package:clingfy/app/settings/widgets/about_section.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutView extends StatefulWidget {
  const AboutView({super.key});

  static const routeName = '/about';

  @override
  State<AboutView> createState() => _AboutViewState();
}

class _AboutViewState extends State<AboutView> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _initPackageInfo();
  }

  Future<void> _initPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _packageInfo = info;
      });
    }
  }

  Future<void> _launchUrl(String urlString) async {
    final url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.aboutThisApp,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    AppButton(
                      label: l10n.close,
                      icon: CupertinoIcons.xmark,
                      variant: AppButtonVariant.secondary,
                      onPressed: () {
                        final navigator = Navigator.of(context);
                        if (navigator.canPop()) {
                          navigator.pop();
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.05),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        Icon(
                          CupertinoIcons.video_camera_solid,
                          size: 80,
                          color: theme.primaryColor,
                        ),
                        const SizedBox(height: 24),

                        AboutSection(packageInfo: _packageInfo),

                        const SizedBox(height: 24),

                        Text(
                          isWindows()
                              ? l10n.appDescriptionWindows
                              : l10n.appDescription,
                          style: theme.textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),

                        const SizedBox(height: 32),
                        const Divider(),

                        _buildLink(
                          context,
                          l10n.visitWebsite,
                          'https://clingfy.com',
                          CupertinoIcons.globe,
                        ),
                        _buildLink(
                          context,
                          l10n.contactSupport,
                          'mailto:contact@clingfy.com',
                          CupertinoIcons.mail,
                        ),
                        _buildLink(
                          context,
                          l10n.privacyPolicy,
                          'https://clingfy.com/privacy',
                          CupertinoIcons.shield,
                        ),
                        _buildLink(
                          context,
                          l10n.termsOfService,
                          'https://clingfy.com/terms',
                          CupertinoIcons.doc_text,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLink(
    BuildContext context,
    String label,
    String url,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        onTap: () => _launchUrl(url),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const Spacer(),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 14,
                  color: theme.hintColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
