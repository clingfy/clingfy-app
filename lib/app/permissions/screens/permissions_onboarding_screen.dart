import 'dart:async';

import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class PermissionsOnboardingScreen extends StatefulWidget {
  const PermissionsOnboardingScreen({
    super.key,
    required this.controller,
    this.initialStep = 0,
    required this.onFinished,
  });

  final PermissionsController controller;
  final int initialStep;
  final VoidCallback onFinished;

  @override
  State<PermissionsOnboardingScreen> createState() =>
      _PermissionsOnboardingScreenState();
}

/// Phase 10.2: the onboarding journey is a per-platform step list. Windows
/// has no screen-recording or accessibility permission, so its journey is
/// Welcome -> Mic + Camera; showing the macOS steps there meant a dead
/// "Restart App" button and "macOS requires this" copy on Windows.
enum _OnboardingStep { welcome, screen, audioCamera, cursorMagic }

class _PermissionsOnboardingScreenState
    extends State<PermissionsOnboardingScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final PageController _page;
  late final AnimationController _animController;

  final List<_OnboardingStep> _steps = isWindows()
      ? const [_OnboardingStep.welcome, _OnboardingStep.audioCamera]
      : const [
          _OnboardingStep.welcome,
          _OnboardingStep.screen,
          _OnboardingStep.audioCamera,
          _OnboardingStep.cursorMagic,
        ];

  late int _index;

  // Emotional-design: give autonomy on optional steps,
  // and show “done” even when user intentionally skips.
  bool _studioSkipped = false;
  bool _magicSkipped = false;

  PermissionsController get c => widget.controller;

  AppLocalizations _l10n(BuildContext context) =>
      AppLocalizations.of(context) ??
      lookupAppLocalizations(
        Localizations.maybeLocaleOf(context) ??
            WidgetsBinding.instance.platformDispatcher.locale,
      );

  @override
  void initState() {
    super.initState();
    // Clamp the persisted step: the saved index may exceed the shorter
    // Windows journey (or a journey that shrank between versions).
    _index = widget.initialStep.clamp(0, _steps.length - 1).toInt();
    _page = PageController(initialPage: _index);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addObserver(this);
    c.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _page.dispose();
    _animController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.refresh();
  }

  Future<void> _finish() async {
    await c.setOnboardingSeen(true);
    await c.resetOnboardingStep();
    widget.onFinished();
  }

  void _next() => _page.nextPage(
    duration: const Duration(milliseconds: 400),
    curve: Curves.fastEaseInToSlowEaseOut,
  );

  void _back() => _page.previousPage(
    duration: const Duration(milliseconds: 400),
    curve: Curves.fastEaseInToSlowEaseOut,
  );

  void _goTo(int target) {
    _page.animateToPage(
      target,
      duration: const Duration(milliseconds: 400),
      curve: Curves.fastEaseInToSlowEaseOut,
    );
  }

  bool _isStepDone(int idx) {
    if (idx < 0 || idx >= _steps.length) return false;
    switch (_steps[idx]) {
      case _OnboardingStep.welcome:
        return true;
      case _OnboardingStep.screen:
        return c.screenRecording;
      case _OnboardingStep.audioCamera:
        return _studioSkipped || c.microphone || c.camera;
      case _OnboardingStep.cursorMagic:
        return _magicSkipped || c.accessibility;
    }
  }

  String _stepLabel(BuildContext context) {
    final l10n = _l10n(context);
    return l10n.permissionsOnboardingStepCount(_index + 1, _steps.length);
  }

  IconData _railIconFor(_OnboardingStep step) {
    switch (step) {
      case _OnboardingStep.welcome:
        return CupertinoIcons.hand_raised;
      case _OnboardingStep.screen:
        return CupertinoIcons.desktopcomputer;
      case _OnboardingStep.audioCamera:
        return CupertinoIcons.mic;
      case _OnboardingStep.cursorMagic:
        return Icons.mouse_rounded;
    }
  }

  String _railLabelFor(BuildContext context, _OnboardingStep step) {
    final l10n = _l10n(context);
    switch (step) {
      case _OnboardingStep.welcome:
        return l10n.permissionsOnboardingWelcomeRail;
      case _OnboardingStep.screen:
        return l10n.permissionsScreenRecording;
      case _OnboardingStep.audioCamera:
        return l10n.permissionsOnboardingMicCameraRail;
      case _OnboardingStep.cursorMagic:
        return l10n.permissionsAccessibility;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canGoNext = true;
    final isLast = _index == _steps.length - 1;

    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final railColor = theme.colorScheme.surface;
    final accentColor = theme.colorScheme.primary;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            if (c.loading) {
              return Center(
                child: isMac()
                    ? const macos.ProgressCircle()
                    : const CircularProgressIndicator(),
              );
            }

            return Row(
              children: [
                // Left Rail (Journey)
                Container(
                  width: 104,
                  color: railColor,
                  child: Column(
                    children: [
                      SizedBox(height: spacing.xxl + spacing.sm),
                      for (var i = 0; i < _steps.length; i++) ...[
                        if (i > 0) _railDivider(),
                        _buildRailItem(
                          icon: _railIconFor(_steps[i]),
                          label: _railLabelFor(context, _steps[i]),
                          index: i,
                          accentColor: accentColor,
                        ),
                      ],
                    ],
                  ),
                ),

                const VerticalDivider(width: 1, thickness: 1),

                // Main Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: PageView(
                          controller: _page,
                          physics: const NeverScrollableScrollPhysics(),
                          onPageChanged: (i) {
                            setState(() => _index = i);
                            unawaited(c.setOnboardingStep(i));
                          },
                          children: [
                            for (final step in _steps)
                              switch (step) {
                                _OnboardingStep.welcome => _welcome(context),
                                _OnboardingStep.screen => _screenPermission(
                                  context,
                                ),
                                _OnboardingStep.audioCamera => _audioCamera(
                                  context,
                                ),
                                _OnboardingStep.cursorMagic => _cursorMagic(
                                  context,
                                ),
                              },
                          ],
                        ),
                      ),
                      _bottomBar(context, canGoNext: canGoNext, isLast: isLast),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _railDivider() {
    final spacing = Theme.of(context).appSpacing;
    return Container(
      width: 2,
      height: spacing.md,
      color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
    );
  }

  Widget _buildRailItem({
    required IconData icon,
    required String label,
    required int index,
    required Color accentColor,
  }) {
    final isSelected = _index == index;
    final isDone = _isStepDone(index);
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;

    return GestureDetector(
      onTap: () => _goTo(index),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: EdgeInsets.symmetric(
            horizontal: spacing.sm,
            vertical: spacing.xs,
          ),
          padding: EdgeInsets.symmetric(vertical: spacing.md),
          decoration: BoxDecoration(
            color: isSelected
                ? accentColor.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  AnimatedScale(
                    scale: isSelected ? 1.08 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      icon,
                      color: isSelected
                          ? accentColor
                          : theme.iconTheme.color?.withValues(alpha: 0.5),
                      size: 26,
                    ),
                  ),
                  if (isDone && index != 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: TweenAnimationBuilder(
                        tween: Tween<double>(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.elasticOut,
                        builder: (context, val, _) {
                          return Transform.scale(
                            scale: val,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.scaffoldBackgroundColor,
                                  width: 2,
                                ),
                              ),
                              padding: const EdgeInsets.all(2),
                              child: const Icon(
                                CupertinoIcons.checkmark,
                                size: 8,
                                color: Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
              SizedBox(height: spacing.sm - 2),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                softWrap: true,
                style: typography.caption.copyWith(
                  color: isSelected
                      ? accentColor
                      : theme.textTheme.bodySmall?.color?.withValues(
                          alpha: 0.6,
                        ),
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Emotional blocks ----------

  Widget _trustBlock(
    BuildContext context, {
    required List<String> lines,
    IconData icon = CupertinoIcons.shield_lefthalf_fill,
  }) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final accent = theme.colorScheme.primary;

    return Container(
      padding: EdgeInsets.all(spacing.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          SizedBox(width: spacing.md - 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines
                  .map(
                    (t) => Padding(
                      padding: EdgeInsets.only(bottom: spacing.xs),
                      child: Text(
                        t,
                        style: theme.textTheme.bodySmall?.copyWith(
                          height: 1.25,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void _showWhySheet({
    required String title,
    required String subtitle,
    required List<String> bullets,
    String? footer,
  }) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    AppDialog.show<void>(
      context,
      title: title,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle,
              style: typography.body.copyWith(
                color: theme.textTheme.bodyMedium?.color?.withValues(
                  alpha: 0.75,
                ),
              ),
            ),
            SizedBox(height: spacing.lg),
            ...bullets.map(
              (b) => Padding(
                padding: EdgeInsets.only(bottom: spacing.md - 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '•  ',
                      style: typography.panelTitle.copyWith(fontSize: 16),
                    ),
                    Expanded(child: Text(b, style: typography.body)),
                  ],
                ),
              ),
            ),
            if (footer != null) ...[
              SizedBox(height: spacing.sm - 2),
              Text(
                footer,
                style: typography.bodyMuted.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withValues(
                    alpha: 0.75,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- Card shell ----------

  Widget _card(
    BuildContext context, {
    required String emoji,
    required String title,
    required String subtitle,
    required Widget child,
    String? heroAsset,
  }) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final accent = theme.colorScheme.primary;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(spacing.dialog + spacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Visceral: branded glow + optional hero image
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(spacing.panel - 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: RadialGradient(
                    center: Alignment.topLeft,
                    radius: 1.4,
                    colors: [
                      accent.withValues(alpha: 0.22),
                      theme.scaffoldBackgroundColor,
                    ],
                  ),
                  border: Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      emoji,
                      style: typography.pageTitle.copyWith(fontSize: 40),
                    ),
                    SizedBox(width: spacing.md + 2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _stepLabel(context),
                            style: typography.bodyMuted.copyWith(
                              color: theme.textTheme.bodySmall?.color
                                  ?.withValues(alpha: 0.7),
                            ),
                          ),
                          SizedBox(height: spacing.sm - 2),
                          Text(
                            title,
                            style: typography.pageTitle.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          SizedBox(height: spacing.sm),
                          Text(
                            subtitle,
                            style: typography.body.copyWith(
                              color: theme.textTheme.bodyMedium?.color
                                  ?.withValues(alpha: 0.75),
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (heroAsset != null) ...[
                      SizedBox(width: spacing.lg),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          heroAsset,
                          width: 160,
                          height: 86,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              SizedBox(height: spacing.panel - 2),

              // Content Area
              Container(
                padding: EdgeInsets.all(spacing.panel + 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.35),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Permission row (kept mostly as-is) ----------

  Widget _permRow({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required VoidCallback onRequest,
    required String buttonLabel,
    VoidCallback? onSecondary,
    String? secondaryLabel,
  }) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final accent = theme.colorScheme.primary;
    final l10n = _l10n(context);

    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(spacing.md),
          decoration: BoxDecoration(
            color: isGranted
                ? Colors.green.withValues(alpha: 0.10)
                : accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            isGranted ? CupertinoIcons.checkmark : icon,
            color: isGranted ? Colors.green : accent,
            size: 28,
          ),
        ),
        SizedBox(width: spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: typography.panelTitle.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              SizedBox(height: spacing.xs),
              Text(description, style: typography.bodyMuted),
            ],
          ),
        ),
        SizedBox(width: spacing.lg),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: isGranted
              ? Container(
                  key: const ValueKey('granted'),
                  padding: EdgeInsets.symmetric(
                    horizontal: spacing.md,
                    vertical: spacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    l10n.permissionsGranted,
                    style: typography.value.copyWith(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              : Row(
                  key: const ValueKey('action'),
                  children: [
                    if (onSecondary != null)
                      Padding(
                        padding: EdgeInsets.only(right: spacing.sm),
                        child: AppButton(
                          label: secondaryLabel ?? '',
                          variant: AppButtonVariant.secondary,
                          onPressed: onSecondary,
                        ),
                      ),
                    AppButton(label: buttonLabel, onPressed: onRequest),
                  ],
                ),
        ),
      ],
    );
  }

  // ---------- Steps ----------

  Widget _welcome(BuildContext context) {
    final l10n = _l10n(context);
    return _card(
      context,
      emoji: '👋',
      title: l10n.permissionsOnboardingWelcomeTitle,
      subtitle: l10n.permissionsOnboardingWelcomeSubtitle,
      heroAsset: isWindows()
          ? 'assets/images/app-banner-windows.png'
          : 'assets/images/app-banner-macos.png',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _trustBlock(
            context,
            lines: isWindows()
                ? [
                    l10n.permissionsOnboardingTrustLocalFirstWindows,
                    l10n.permissionsOnboardingTrustPermissionControlWindows,
                    // The headline Windows truth: no screen-recording
                    // permission exists; recording works immediately.
                    l10n.permissionsOnboardingWindowsNoScreenGrant,
                  ]
                : [
                    l10n.permissionsOnboardingTrustLocalFirst,
                    l10n.permissionsOnboardingTrustPermissionControl,
                  ],
          ),
          const Divider(height: 28),
          _featureListTile(
            CupertinoIcons.film,
            l10n.permissionsOnboardingFeatureExportsTitle,
            l10n.permissionsOnboardingFeatureExportsSubtitle,
          ),
          const Divider(height: 28),
          _featureListTile(
            CupertinoIcons.scope,
            l10n.permissionsOnboardingFeatureZoomTitle,
            l10n.permissionsOnboardingFeatureZoomSubtitle,
          ),
        ],
      ),
    );
  }

  Widget _featureListTile(IconData icon, String title, String sub) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        SizedBox(width: spacing.md),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: typography.body,
              children: [
                TextSpan(
                  text: '$title\n',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: sub,
                  style: TextStyle(
                    color: theme.textTheme.bodySmall?.color?.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _screenPermission(BuildContext context) {
    final l10n = _l10n(context);
    return _card(
      context,
      emoji: '🖥️',
      title: l10n.permissionsOnboardingScreenTitle,
      subtitle: l10n.permissionsOnboardingScreenSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _permRow(
            icon: CupertinoIcons.desktopcomputer,
            title: l10n.permissionsScreenRecording,
            description: l10n.permissionsScreenRecordingHelp,
            isGranted: c.screenRecording,
            buttonLabel: l10n.permissionsGrantAccess,
            onRequest: () async => c.requestScreen(),
            secondaryLabel: l10n.openSettings,
            onSecondary: () => c.openScreenSettings(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.permissionsOnboardingWhyAreYouAsking,
              icon: CupertinoIcons.question_circle,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => _showWhySheet(
                title: l10n.permissionsOnboardingWhyScreenTitle,
                subtitle: l10n.permissionsOnboardingWhyScreenSubtitle,
                bullets: [
                  l10n.permissionsOnboardingWhyScreenBullet1,
                  l10n.permissionsOnboardingWhyScreenBullet2,
                  l10n.permissionsOnboardingWhyScreenBullet3,
                ],
                footer: l10n.permissionsOnboardingWhyScreenFooter,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _trustBlock(
            context,
            lines: [
              l10n.permissionsOnboardingScreenTrustLine1,
              l10n.permissionsOnboardingScreenTrustLine2,
            ],
          ),
          if (c.screenRecording) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.info_circle,
                    size: 20,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.permissionsOnboardingRestartHint,
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: l10n.restartApp,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.regular,
                    onPressed: () => c.relaunch(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _audioCamera(BuildContext context) {
    final l10n = _l10n(context);
    return _card(
      context,
      emoji: '🎙️',
      title: l10n.permissionsOnboardingVoiceCameraTitle,
      subtitle: l10n.permissionsOnboardingVoiceCameraSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _permRow(
            icon: CupertinoIcons.mic_fill,
            title: l10n.permissionsMicrophone,
            description: l10n.permissionsOnboardingMicrophoneDescription,
            isGranted: c.microphone,
            buttonLabel: l10n.permissionsOnboardingEnableMic,
            onRequest: () => c.requestMic(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.permissionsOnboardingWhyIsThisNeeded,
              icon: CupertinoIcons.question_circle,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => _showWhySheet(
                title: l10n.permissionsOnboardingWhyMicrophoneTitle,
                subtitle: l10n.permissionsOnboardingWhyMicrophoneSubtitle,
                bullets: [
                  l10n.permissionsOnboardingWhyMicrophoneBullet1,
                  l10n.permissionsOnboardingWhyMicrophoneBullet2,
                  l10n.permissionsOnboardingWhyMicrophoneBullet3,
                ],
              ),
            ),
          ),
          const Divider(height: 26),
          _permRow(
            icon: CupertinoIcons.video_camera_solid,
            title: l10n.permissionsCamera,
            description: l10n.permissionsOnboardingCameraDescription,
            isGranted: c.camera,
            buttonLabel: l10n.permissionsOnboardingEnableCamera,
            onRequest: () => c.requestCam(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.permissionsOnboardingWhyIsThisNeeded,
              icon: CupertinoIcons.question_circle,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => _showWhySheet(
                title: l10n.permissionsOnboardingWhyCameraTitle,
                subtitle: l10n.permissionsOnboardingWhyCameraSubtitle,
                bullets: [
                  l10n.permissionsOnboardingWhyCameraBullet1,
                  l10n.permissionsOnboardingWhyCameraBullet2,
                  l10n.permissionsOnboardingWhyCameraBullet3,
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          _trustBlock(
            context,
            lines: [
              l10n.permissionsOnboardingAudioTrustLine1,
              l10n.permissionsOnboardingAudioTrustLine2,
            ],
            icon: CupertinoIcons.heart_fill,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.permissionsOnboardingSkipForNow,
              icon: CupertinoIcons.forward,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => setState(() => _studioSkipped = true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cursorMagic(BuildContext context) {
    final l10n = _l10n(context);
    return _card(
      context,
      emoji: '✨',
      title: l10n.permissionsOnboardingCursorTitle,
      subtitle: l10n.permissionsOnboardingCursorSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _permRow(
            icon: CupertinoIcons.cursor_rays,
            title: l10n.permissionsAccessibility,
            description: l10n.permissionsOnboardingAccessibilityDescription,
            isGranted: c.accessibility,
            buttonLabel: l10n.openSettings,
            onRequest: () => c.openAccessibility(),
            secondaryLabel: l10n.permissionsOnboardingCheck,
            onSecondary: () => c.refresh(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.permissionsOnboardingWhyAreYouAsking,
              icon: CupertinoIcons.question_circle,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => _showWhySheet(
                title: l10n.permissionsOnboardingWhyAccessibilityTitle,
                subtitle: l10n.permissionsOnboardingWhyAccessibilitySubtitle,
                bullets: [
                  l10n.permissionsOnboardingWhyAccessibilityBullet1,
                  l10n.permissionsOnboardingWhyAccessibilityBullet2,
                  l10n.permissionsOnboardingWhyAccessibilityBullet3,
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          _trustBlock(
            context,
            lines: [
              l10n.permissionsOnboardingCursorTrustLine1,
              l10n.permissionsOnboardingCursorTrustLine2,
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: l10n.permissionsOnboardingSkipForNow,
              icon: CupertinoIcons.forward,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.regular,
              onPressed: () => setState(() => _magicSkipped = true),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Bottom bar ----------

  Widget _bottomBar(
    BuildContext context, {
    required bool canGoNext,
    required bool isLast,
  }) {
    final l10n = _l10n(context);
    final spacing = Theme.of(context).appSpacing;
    return Container(
      padding: EdgeInsets.all(spacing.panel + 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.10),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_index > 0)
            AppButton(
              label: l10n.permissionsOnboardingBack,
              icon: CupertinoIcons.chevron_left,
              variant: AppButtonVariant.secondary,
              onPressed: _back,
            )
          else
            const SizedBox(width: 80),

          AnimatedBuilder(
            animation: _animController,
            builder: (context, child) {
              final ready = canGoNext;
              final scale = ready && !isLast
                  ? 1.0 + (_animController.value * 0.03)
                  : 1.0;

              return Transform.scale(
                scale: scale,
                child: AppButton(
                  label: isLast
                      ? l10n.permissionsOnboardingLetsRecord
                      : l10n.permissionsOnboardingNext,
                  icon: isLast ? null : CupertinoIcons.chevron_right,
                  variant: AppButtonVariant.primary,
                  onPressed: isLast ? _finish : (canGoNext ? _next : null),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
