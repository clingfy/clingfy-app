import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

class PermissionsSettingsSection extends StatefulWidget {
  const PermissionsSettingsSection({super.key});

  @override
  State<PermissionsSettingsSection> createState() =>
      _PermissionsSettingsSectionState();
}

class _PermissionsSettingsSectionState extends State<PermissionsSettingsSection>
    with WidgetsBindingObserver {
  late final PermissionsController _controller;
  bool _hasLoadedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = PermissionsController(bridge: NativeBridge.instance);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _refreshPermissions() async {
    await _controller.refresh();
    if (!mounted || _hasLoadedOnce) {
      return;
    }
    setState(() {
      _hasLoadedOnce = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final cards = _buildPermissionCards(context);

        return buildSectionPage(
          context,
          children: [
            SettingsCard(
              title: l10n.permissionsTitle,
              infoTooltip: l10n.permissionsHelpText,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(
                    loading: _controller.loading,
                    onRefresh: _controller.loading ? null : _refreshPermissions,
                  ),
                  const SizedBox(height: 16),
                  if (!_hasLoadedOnce && _controller.loading)
                    const _InitialLoadingState()
                  else ...[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: cards
                          .map(
                            (card) => Padding(
                              padding: EdgeInsets.only(
                                bottom: card == cards.last ? 0 : 12,
                              ),
                              child: _PermissionCard(
                                data: card,
                                loading: _controller.loading,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 16),
                    AppInlineNotice(message: l10n.permissionsChangedHint),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<_PermissionCardData> _buildPermissionCards(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _PermissionCardData(
        id: 'screenRecording',
        icon: CupertinoIcons.desktopcomputer,
        title: l10n.permissionsScreenRecording,
        helpText: l10n.permissionsScreenRecordingHelp,
        required: true,
        granted: _controller.screenRecording,
        primaryLabel: _controller.screenRecording
            ? null
            : l10n.permissionsGrantAccess,
        onPrimaryPressed: _controller.screenRecording
            ? null
            : _controller.requestScreen,
        secondaryLabel: l10n.openSettings,
        onSecondaryPressed: _controller.openScreenSettings,
      ),
      _PermissionCardData(
        id: 'microphone',
        icon: CupertinoIcons.mic,
        title: l10n.permissionsMicrophone,
        helpText: l10n.permissionsMicrophoneHelp,
        required: false,
        granted: _controller.microphone,
        primaryLabel: _controller.microphone
            ? null
            : l10n.permissionsGrantAccess,
        onPrimaryPressed: _controller.microphone
            ? null
            : _controller.requestMic,
        secondaryLabel: l10n.openSettings,
        onSecondaryPressed: _controller.openMicrophoneSettings,
      ),
      _PermissionCardData(
        id: 'camera',
        icon: CupertinoIcons.video_camera_solid,
        title: l10n.permissionsCamera,
        helpText: l10n.permissionsCameraHelp,
        required: false,
        granted: _controller.camera,
        primaryLabel: _controller.camera ? null : l10n.permissionsGrantAccess,
        onPrimaryPressed: _controller.camera ? null : _controller.requestCam,
        secondaryLabel: l10n.openSettings,
        onSecondaryPressed: _controller.openCameraSettings,
      ),
      _PermissionCardData(
        id: 'accessibility',
        icon: Icons.mouse_rounded,
        title: l10n.permissionsAccessibility,
        helpText: l10n.permissionsAccessibilityHelp,
        required: false,
        granted: _controller.accessibility,
        primaryLabel: l10n.openSettings,
        onPrimaryPressed: _controller.openAccessibility,
      ),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.loading, required this.onRefresh});

  final bool loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            children: [
              Text(
                l10n.permissionsTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (loading) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        AppButton(
          key: const ValueKey('permissions-refresh'),
          label: l10n.permissionsRefreshStatus,
          icon: CupertinoIcons.arrow_clockwise,
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.regular,
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _InitialLoadingState extends StatelessWidget {
  const _InitialLoadingState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.loading,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.data, required this.loading});

  final _PermissionCardData data;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final granted = data.granted;
    final backgroundColor = granted
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45)
        : theme.colorScheme.surface.withValues(alpha: 0.9);

    return Container(
      key: ValueKey('permission-card-${data.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  data.icon,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.helpText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PermissionPill(
                label: granted
                    ? l10n.permissionsGranted
                    : l10n.permissionsNotGranted,
                backgroundColor: granted
                    ? Colors.green.withValues(alpha: 0.12)
                    : theme.colorScheme.primary.withValues(alpha: 0.12),
                foregroundColor: granted
                    ? Colors.green.shade700
                    : theme.colorScheme.primary,
              ),
              _PermissionPill(
                label: data.required
                    ? l10n.permissionsRequired
                    : l10n.permissionsOptional,
                backgroundColor: theme.colorScheme.surface.withValues(
                  alpha: 0.9,
                ),
                foregroundColor: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (data.primaryLabel != null)
                AppButton(
                  key: ValueKey('permission-primary-${data.id}'),
                  label: data.primaryLabel!,
                  size: AppButtonSize.regular,
                  onPressed: loading ? null : data.onPrimaryPressed,
                ),
              if (data.secondaryLabel != null)
                AppButton(
                  key: ValueKey('permission-secondary-${data.id}'),
                  label: data.secondaryLabel!,
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.regular,
                  onPressed: loading ? null : data.onSecondaryPressed,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermissionPill extends StatelessWidget {
  const _PermissionPill({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: foregroundColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _PermissionCardData {
  const _PermissionCardData({
    required this.id,
    required this.icon,
    required this.title,
    required this.helpText,
    required this.required,
    required this.granted,
    this.primaryLabel,
    this.onPrimaryPressed,
    this.secondaryLabel,
    this.onSecondaryPressed,
  });

  final String id;
  final IconData icon;
  final String title;
  final String helpText;
  final bool required;
  final bool granted;
  final String? primaryLabel;
  final VoidCallback? onPrimaryPressed;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryPressed;
}
