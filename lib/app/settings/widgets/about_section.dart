import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';

class AboutSection extends StatefulWidget {
  final PackageInfo? packageInfo;

  const AboutSection({super.key, this.packageInfo});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection>
    with SingleTickerProviderStateMixin {
  int _tapCount = 0;
  bool _showDebugInfo = false;
  String? _noticeText;
  AppInlineNoticeVariant _noticeVariant = AppInlineNoticeVariant.info;

  late final AnimationController _debugAnimController;
  late final Animation<double> _debugAnimation;

  @override
  void initState() {
    super.initState();
    _debugAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _debugAnimation = CurvedAnimation(
      parent: _debugAnimController,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _debugAnimController.dispose();
    super.dispose();
  }

  void _handleSecretTap() {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _tapCount++;
      if (_tapCount >= 5) {
        _showDebugInfo = !_showDebugInfo;
        _tapCount = 0;

        if (_showDebugInfo) {
          _debugAnimController.forward();
        } else {
          _debugAnimController.reverse();
        }
        _noticeText = _showDebugInfo
            ? l10n.aboutDeveloperModeEnabled
            : l10n.aboutDeveloperModeDisabled;
        _noticeVariant = AppInlineNoticeVariant.info;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Fallback strings if packageInfo hasn't loaded yet
    final appName = widget.packageInfo?.appName ?? 'Clingfy';
    final versionStr = widget.packageInfo != null
        ? '${widget.packageInfo!.version} (build ${widget.packageInfo!.buildNumber})'
        : '...';

    return Column(
      children: [
        if (_noticeText != null) ...[
          AppInlineNotice(message: _noticeText!, variant: _noticeVariant),
          const SizedBox(height: 16),
        ],
        GestureDetector(
          onTap: _handleSecretTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            children: [
              Text(
                appName,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context)!.version(versionStr),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.hintColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Text(
                AppLocalizations.of(context)!.appDescription,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),

        SizeTransition(
          sizeFactor: _debugAnimation,
          axisAlignment: -1.0,
          child: FadeTransition(
            opacity: _debugAnimation,
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: _buildDebugCard(theme),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDebugCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLocalizations.of(context)!.aboutBuildMetadata,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: theme.primaryColor,
                  letterSpacing: 1.2,
                ),
              ),
              AppIconButton(
                icon: CupertinoIcons.doc_on_clipboard,
                tooltip: AppLocalizations.of(context)!.copy,
                onPressed: () {
                  final info =
                      "Commit: ${BuildConfig.commitHash}\nBranch: ${BuildConfig.branch}\nBuild: ${BuildConfig.buildId}";
                  Clipboard.setData(ClipboardData(text: info));
                  setState(() {
                    _noticeText = AppLocalizations.of(
                      context,
                    )!.copiedToClipboard;
                    _noticeVariant = AppInlineNoticeVariant.success;
                  });
                },
              ),
            ],
          ),
          const Divider(),
          _buildDebugRow(
            AppLocalizations.of(context)!.aboutBuildCommit,
            BuildConfig.commitHash,
          ),
          _buildDebugRow(
            AppLocalizations.of(context)!.aboutBuildBranch,
            BuildConfig.branch,
          ),
          _buildDebugRow(
            AppLocalizations.of(context)!.aboutBuildId,
            BuildConfig.buildId,
          ),
          _buildDebugRow(
            AppLocalizations.of(context)!.aboutBuildDate,
            DateFormat(
              'yyyy-MM-dd HH:mm',
            ).format(BuildConfig.buildDate.toLocal()),
          ),
          _buildDebugRow(
            AppLocalizations.of(context)!.aboutBuildMetadata,
            '${BuildConfig.buildName}+${BuildConfig.buildNumber}',
          ),
        ],
      ),
    );
  }

  Widget _buildDebugRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            "$label: ",
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, fontFamily: 'Monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
