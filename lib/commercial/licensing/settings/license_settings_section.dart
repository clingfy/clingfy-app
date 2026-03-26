import 'dart:async';
import 'dart:math' as math;

import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/commercial/licensing/models/license_plan.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/commercial/licensing/widgets/paywall_dialog.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class LicenseSettingsSection extends StatefulWidget {
  const LicenseSettingsSection({super.key, this.paywallLauncher});

  final Future<bool?> Function(BuildContext context)? paywallLauncher;

  @override
  State<LicenseSettingsSection> createState() => _LicenseSettingsSectionState();
}

class _LicenseSettingsSectionState extends State<LicenseSettingsSection> {
  static const _celebrationDuration = Duration(milliseconds: 1100);

  late final ConfettiController _celebrationController;
  Timer? _hideCelebrationTimer;
  bool _showCelebration = false;
  String? _noticeText;
  AppInlineNoticeVariant _noticeVariant = AppInlineNoticeVariant.info;

  @override
  void initState() {
    super.initState();
    _celebrationController = ConfettiController(duration: _celebrationDuration);
  }

  @override
  void dispose() {
    _hideCelebrationTimer?.cancel();
    _celebrationController.dispose();
    super.dispose();
  }

  Future<bool?> _openPaywall() {
    final launcher = widget.paywallLauncher;
    if (launcher != null) {
      return launcher(context);
    }
    return PaywallDialog.show(context, showSuccessSnackbar: false);
  }

  Future<void> _handlePrimaryAction(LicenseController license) async {
    final action = license.primaryLicenseActionType;
    if (action == LicensePrimaryAction.subscriptionActive ||
        action == LicensePrimaryAction.lifetimeActive) {
      return;
    }

    final activated = await _openPaywall();
    if (!mounted) {
      return;
    }

    if (activated == true) {
      _triggerCelebration();
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _noticeText = l10n.paywallActivationSuccess;
        _noticeVariant = AppInlineNoticeVariant.success;
      });
    }
  }

  void _triggerCelebration() {
    _hideCelebrationTimer?.cancel();
    setState(() {
      _showCelebration = true;
    });
    _celebrationController.stop();
    _celebrationController.play();
    _hideCelebrationTimer = Timer(_celebrationDuration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showCelebration = false;
      });
    });
  }

  String _planLabel(AppLocalizations l10n, LicensePlan plan) {
    switch (plan) {
      case LicensePlan.trial:
        return l10n.licensePlanTrial;
      case LicensePlan.lifetime:
        return l10n.licensePlanLifetime;
      case LicensePlan.subscription:
        return l10n.licensePlanSubscription;
      case LicensePlan.starter:
        return l10n.licensePlanStarter;
      case LicensePlan.unknown:
        return l10n.unknown;
    }
  }

  String _summaryMessage(AppLocalizations l10n, LicenseController license) {
    final plan = license.currentPlanType;
    if (plan == LicensePlan.trial) {
      return l10n.licenseSummaryTrial(license.trialExportsRemaining);
    }

    if (plan == LicensePlan.subscription &&
        license.isEntitledPro &&
        license.isUpdateCovered) {
      return l10n.licenseSummarySubscriptionActive;
    }

    if (plan == LicensePlan.lifetime) {
      if (license.isUpdatesExpired) {
        return l10n.licenseSummaryLifetimeExpired;
      }
      if (license.isUpdatesExpiringSoon) {
        final expiresAt = license.state.updatesExpiresAt;
        final daysLeft = expiresAt == null
            ? 0
            : expiresAt.difference(DateTime.now()).inDays.clamp(0, 9999);
        return l10n.licenseSummaryLifetimeExpiringSoon(daysLeft);
      }
      if (license.isEntitledPro && license.isUpdateCovered) {
        return l10n.licenseSummaryLifetimeCovered;
      }
    }

    return l10n.licenseSummaryStarter;
  }

  String _primaryActionLabel(
    AppLocalizations l10n,
    LicensePrimaryAction action,
  ) {
    switch (action) {
      case LicensePrimaryAction.activateOrUpgrade:
        return l10n.licenseActivateOrUpgrade;
      case LicensePrimaryAction.upgradeToPro:
        return l10n.licenseUpgradeToPro;
      case LicensePrimaryAction.activateKeyOnly:
        return l10n.licenseActivateKeyOnly;
      case LicensePrimaryAction.extendUpdates:
        return l10n.licenseExtendUpdates;
      case LicensePrimaryAction.subscriptionActive:
        return l10n.licenseSubscriptionActive;
      case LicensePrimaryAction.lifetimeActive:
        return l10n.licenseLifetimeActive;
    }
  }

  String _formatDate(BuildContext context, DateTime value) {
    return MaterialLocalizations.of(context).formatShortDate(value.toLocal());
  }

  String _maskedLicenseKey(String? key) {
    final raw = key?.trim() ?? '';
    if (raw.isEmpty) {
      return '—';
    }

    final segments = raw.split('-').where((segment) => segment.isNotEmpty);
    final parts = segments.toList(growable: false);
    if (parts.isEmpty) {
      return '—';
    }

    if (parts.length == 1) {
      return _maskFirstSegment(parts.first);
    }

    final masked = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (i == 0) {
        masked.add(_maskFirstSegment(part));
      } else if (i == parts.length - 1) {
        masked.add(_maskLastSegment(part));
      } else {
        masked.add(_repeatBullet(part.length.clamp(4, 12)));
      }
    }
    return masked.join('-');
  }

  String _maskFirstSegment(String value) {
    if (value.length <= 2) {
      return value;
    }
    return '${value.substring(0, 2)}${_repeatBullet(value.length - 2)}';
  }

  String _maskLastSegment(String value) {
    if (value.length <= 2) {
      return value;
    }
    return '${_repeatBullet(value.length - 2)}${value.substring(value.length - 2)}';
  }

  String _repeatBullet(int count) {
    if (count <= 0) {
      return '';
    }
    return List.filled(count, '•').join();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final license = context.watch<LicenseController>();

    final planType = license.currentPlanType;
    final entitlementLabel = license.isEntitledPro
        ? l10n.licenseStatusEntitled
        : l10n.licenseStatusNotEntitled;
    final coverageLabel = license.isUpdateCovered
        ? l10n.licenseUpdatesCovered
        : l10n.licenseUpdatesExpired;
    final linkedLabel = license.hasLinkedKey
        ? l10n.licenseDeviceLinked
        : l10n.licenseDeviceNotLinked;
    final activationDate =
        license.memberSince ?? license.activatedOnThisDeviceAt;
    final activationLabel = license.memberSince != null
        ? l10n.licenseMemberSince
        : l10n.licenseActivatedOnThisDevice;
    final primaryAction = license.primaryLicenseActionType;
    final primaryActionLabel = _primaryActionLabel(l10n, primaryAction);

    return buildSectionPage(
      context,
      children: [
        if (_noticeText != null) ...[
          AppInlineNotice(message: _noticeText!, variant: _noticeVariant),
          const SizedBox(height: 16),
        ],
        Stack(
          clipBehavior: Clip.none,
          children: [
            SettingsCard(
              title: l10n.licenseSummaryHeroTitle,
              infoTooltip: l10n.licenseSummaryHeroSubtitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _StatusPill(
                        label: _planLabel(l10n, planType),
                        icon: CupertinoIcons.star_fill,
                      ),
                      _StatusPill(
                        label: entitlementLabel,
                        icon: license.isEntitledPro
                            ? CupertinoIcons.checkmark_seal_fill
                            : CupertinoIcons.lock,
                      ),
                      _StatusPill(
                        label: coverageLabel,
                        icon: license.isUpdateCovered
                            ? CupertinoIcons.arrow_down_circle_fill
                            : CupertinoIcons.exclamationmark_triangle,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _summaryMessage(l10n, license),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
            if (_showCelebration)
              Positioned.fill(
                child: IgnorePointer(
                  child: _CelebrationOverlay(
                    controller: _celebrationController,
                    key: const Key('license-celebration'),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.licenseDetailsTitle,
          infoTooltip: l10n.licenseDetailsSubtitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow(
                label: l10n.licenseKeyLabel,
                value: _maskedLicenseKey(license.currentKey),
                monospace: true,
              ),
              const SizedBox(height: 10),
              _DetailRow(
                label: activationLabel,
                value: activationDate != null
                    ? _formatDate(context, activationDate)
                    : l10n.none,
              ),
              if (license.state.updatesExpiresAt != null) ...[
                const SizedBox(height: 10),
                _DetailRow(
                  label: l10n.licenseUpdatesUntil,
                  value: _formatDate(context, license.state.updatesExpiresAt!),
                ),
              ],
              const SizedBox(height: 10),
              _DetailRow(label: l10n.licenseLinkStatus, value: linkedLabel),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.licenseActionTitle,
          infoTooltip: l10n.licenseActionSubtitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (primaryAction == LicensePrimaryAction.subscriptionActive ||
                  primaryAction == LicensePrimaryAction.lifetimeActive)
                _NeutralStatusRow(label: primaryActionLabel)
              else
                AppButton(
                  label: primaryActionLabel,
                  icon: CupertinoIcons.star_fill,
                  onPressed: license.isLoading
                      ? null
                      : () => _handlePrimaryAction(license),
                ),
              if (primaryAction == LicensePrimaryAction.upgradeToPro) ...[
                const SizedBox(height: 8),
                AppButton(
                  label: l10n.licenseActivateKeySecondary,
                  variant: AppButtonVariant.secondary,
                  onPressed: license.isLoading
                      ? null
                      : () => _handlePrimaryAction(license),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 190,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            style: monospace
                ? theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')
                : theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _NeutralStatusRow extends StatelessWidget {
  const _NeutralStatusRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.checkmark_circle_fill,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CelebrationOverlay extends StatelessWidget {
  const _CelebrationOverlay({super.key, required this.controller});

  final ConfettiController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = [
      theme.colorScheme.primary,
      theme.colorScheme.tertiary,
      theme.colorScheme.secondary,
      theme.colorScheme.primaryContainer,
      theme.colorScheme.inversePrimary,
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: controller,
            blastDirectionality: BlastDirectionality.explosive,
            emissionFrequency: 0.09,
            numberOfParticles: 22,
            maxBlastForce: 24,
            minBlastForce: 10,
            gravity: 0.24,
            shouldLoop: false,
            colors: colors,
            minimumSize: const Size(5, 5),
            maximumSize: const Size(12, 14),
            createParticlePath: _drawStar,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: ConfettiWidget(
            confettiController: controller,
            blastDirection: -math.pi / 6,
            blastDirectionality: BlastDirectionality.directional,
            emissionFrequency: 0.06,
            numberOfParticles: 11,
            maxBlastForce: 20,
            minBlastForce: 8,
            gravity: 0.3,
            shouldLoop: false,
            colors: colors,
            minimumSize: const Size(4, 4),
            maximumSize: const Size(9, 10),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: ConfettiWidget(
            confettiController: controller,
            blastDirection: -5 * math.pi / 6,
            blastDirectionality: BlastDirectionality.directional,
            emissionFrequency: 0.06,
            numberOfParticles: 11,
            maxBlastForce: 20,
            minBlastForce: 8,
            gravity: 0.3,
            shouldLoop: false,
            colors: colors,
            minimumSize: const Size(4, 4),
            maximumSize: const Size(9, 10),
          ),
        ),
      ],
    );
  }

  static Path _drawStar(Size size) {
    final path = Path();
    final halfWidth = size.width / 2;
    final externalRadius = halfWidth;
    final internalRadius = externalRadius / 2.5;
    const points = 5;

    final angle = (math.pi * 2) / points;
    final halfAngle = angle / 2;

    path.moveTo(size.width, halfWidth);
    for (var i = 0; i < points; i++) {
      path.lineTo(
        halfWidth + (externalRadius * math.cos(angle * i)),
        halfWidth + (externalRadius * math.sin(angle * i)),
      );
      path.lineTo(
        halfWidth + (internalRadius * math.cos((angle * i) + halfAngle)),
        halfWidth + (internalRadius * math.sin((angle * i) + halfAngle)),
      );
    }
    path.close();

    return path;
  }
}
