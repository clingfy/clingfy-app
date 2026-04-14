// lib/widgets/paywall_dialog.dart
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/commercial/licensing/license_error_mapper.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:clingfy/commercial/licensing/models/license_plan.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/theme/app_theme.dart';

class PaywallDialog extends StatefulWidget {
  const PaywallDialog({super.key, this.showSuccessSnackbar = true});

  final bool showSuccessSnackbar;

  static Future<bool?> show(
    BuildContext context, {
    bool showSuccessSnackbar = true,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => PaywallDialog(showSuccessSnackbar: showSuccessSnackbar),
    );
  }

  @override
  State<PaywallDialog> createState() => _PaywallDialogState();
}

class _PaywallDialogState extends State<PaywallDialog> {
  static final Uri _pricingUri = Uri.parse('${BuildConfig.siteURL}/pricing');
  static const String _licensePrefix = 'CLINGFY-';

  final TextEditingController _licenseKeyController = TextEditingController();

  bool _isActivating = false;
  String? _errorText;
  String? _noticeText;
  AppInlineNoticeVariant _noticeVariant = AppInlineNoticeVariant.info;

  @override
  void dispose() {
    _licenseKeyController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _licenseKeyController.text = '';
    _licenseKeyController.addListener(_normalizeLicenseInput);
  }

  void _normalizeLicenseInput() {
    final text = _licenseKeyController.text;
    final upper = text.toUpperCase();

    String normalized = upper;
    if (normalized.startsWith(_licensePrefix)) {
      normalized = normalized.substring(_licensePrefix.length);
    }

    if (normalized != text) {
      _licenseKeyController.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
  }

  Future<void> _activateLicense() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<LicenseController>();

    final rawSuffix = _licenseKeyController.text.trim().toUpperCase();
    final input = rawSuffix.isEmpty ? '' : '$_licensePrefix$rawSuffix';

    if (input.isEmpty) {
      setState(() {
        _errorText = l10n.paywallLicenseKeyRequired;
      });
      return;
    }

    setState(() {
      _isActivating = true;
      _errorText = null;
    });

    final ok = await controller.activateKey(input);
    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _isActivating = false;
      _errorText = controller.state.message.isNotEmpty
          ? localizeLicenseMessage(l10n, controller.state.message)
          : l10n.paywallActivationFailed;
    });
  }

  Future<void> _launchPricingPage() async {
    final l10n = AppLocalizations.of(context)!;
    final launched = await launchUrl(
      _pricingUri,
      mode: LaunchMode.externalApplication,
    );

    if (!mounted) {
      return;
    }

    if (!launched) {
      setState(() {
        _noticeText = l10n.paywallPricingOpenFailed;
        _noticeVariant = AppInlineNoticeVariant.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final license = context.watch<LicenseController>();

    final trialSubtitle = l10n.paywallSubtitleTrial(
      license.state.trialExportsRemaining,
    );
    final subtitle =
        license.state.planType == LicensePlan.trial ||
            license.state.trialExportsRemaining > 0
        ? trialSubtitle
        : l10n.paywallSubtitleStarter;

    final monthlyFeatures = [
      l10n.paywallCardMonthlyFeature1,
      l10n.paywallCardMonthlyFeature2,
      l10n.paywallCardMonthlyFeature3,
    ];
    final lifetimeFeatures = [
      l10n.paywallCardLifetimeFeature1,
      l10n.paywallCardLifetimeFeature2,
      l10n.paywallCardLifetimeFeature3,
      l10n.paywallCardLifetimeFeature4,
    ];
    final extensionFeatures = [
      l10n.paywallCardExtensionFeature1,
      l10n.paywallCardExtensionFeature2,
      l10n.paywallCardExtensionFeature3,
    ];

    final cards = [
      _PricingCard(
        title: l10n.paywallCardMonthlyTitle,
        price: l10n.paywallCardMonthlyPrice,
        period: l10n.paywallCardMonthlyPeriod,
        description: l10n.paywallCardMonthlyDescription,
        features: monthlyFeatures,
        buttonText: l10n.paywallCardMonthlyCta,
        onTap: _launchPricingPage,
      ),
      _PricingCard(
        title: l10n.paywallCardLifetimeTitle,
        price: l10n.paywallCardLifetimePrice,
        period: l10n.paywallCardLifetimePeriod,
        description: l10n.paywallCardLifetimeDescription,
        features: lifetimeFeatures,
        buttonText: l10n.paywallCardLifetimeCta,
        recommendedLabel: l10n.paywallRecommendedBadge,
        isHighlighted: true,
        onTap: _launchPricingPage,
      ),
      _PricingCard(
        title: l10n.paywallCardExtensionTitle,
        price: l10n.paywallCardExtensionPrice,
        period: l10n.paywallCardExtensionPeriod,
        description: l10n.paywallCardExtensionDescription,
        features: extensionFeatures,
        buttonText: l10n.paywallCardExtensionCta,
        onTap: _launchPricingPage,
      ),
    ];

    final width = MediaQuery.of(context).size.width;
    final maxDialogWidth = math.max(360.0, math.min(850.0, width - 48.0));
    final useRow = maxDialogWidth >= 780;

    return Dialog(
      insetPadding: EdgeInsets.all(spacing.dialog),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxDialogWidth),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(spacing.dialog),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.paywallTitle,
                      style: typography.pageTitle.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  AppButton(
                    label: l10n.close,
                    icon: CupertinoIcons.xmark,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.regular,
                    onPressed: () {
                      final navigator = Navigator.of(context);
                      if (navigator.canPop()) {
                        navigator.pop();
                      }
                    },
                  ),
                ],
              ),
              SizedBox(height: spacing.sm),
              Text(
                subtitle,
                style: typography.rowLabel.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                ),
              ),
              if (_noticeText != null) ...[
                SizedBox(height: spacing.lg),
                AppInlineNotice(message: _noticeText!, variant: _noticeVariant),
              ],
              SizedBox(height: spacing.xxl),
              if (useRow)
                Row(
                  children: [
                    Expanded(child: cards[0]),
                    SizedBox(width: spacing.md),
                    Expanded(child: cards[1]),
                    SizedBox(width: spacing.md),
                    Expanded(child: cards[2]),
                  ],
                )
              else
                Column(
                  children: [
                    cards[0],
                    SizedBox(height: spacing.md),
                    cards[1],
                    SizedBox(height: spacing.md),
                    cards[2],
                  ],
                ),
              SizedBox(height: spacing.xxl),
              Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
              SizedBox(height: spacing.lg),
              Text(
                l10n.paywallAlreadyHaveKey,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: spacing.md - 2),
              if (_errorText != null) ...[
                SizedBox(height: spacing.sm - 2),
                Padding(
                  padding: EdgeInsets.only(left: spacing.md),
                  child: Text(
                    _errorText!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _licenseKeyController,
                      autofocus: true,
                      enabled: !_isActivating && !license.isLoading,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        prefixText: 'CLINGFY-',
                        prefixStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.72,
                          ),
                          fontWeight: FontWeight.w600,
                        ),
                        hintText: 'B9E6-3487-CF8C',
                        hintStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.35,
                          ),
                        ),
                        errorText: _errorText,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: theme.dividerColor.withValues(alpha: 0.45),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 1.4,
                          ),
                        ),
                      ),
                      inputFormatters: [LicenseKeySuffixFormatter()],
                      onChanged: (_) {
                        if (_errorText != null) {
                          setState(() {
                            _errorText = null;
                            _noticeText = null;
                          });
                        }
                      },
                      onSubmitted: (_) => _activateLicense(),
                    ),
                  ),
                  SizedBox(width: spacing.md),
                  AppButton(
                    label: _isActivating ? '...' : l10n.paywallActivateKey,
                    onPressed: (_isActivating || license.isLoading)
                        ? null
                        : _activateLicense,
                    size: AppButtonSize.regular,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PricingCard extends StatelessWidget {
  final String title;
  final String price;
  final String period;
  final String description;
  final List<String> features;
  final String buttonText;
  final String? recommendedLabel;
  final bool isHighlighted;
  final VoidCallback onTap;

  const _PricingCard({
    required this.title,
    required this.price,
    required this.period,
    required this.description,
    required this.features,
    required this.buttonText,
    required this.onTap,
    this.recommendedLabel,
    this.isHighlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final borderColor = isHighlighted
        ? theme.colorScheme.primary
        : theme.dividerColor.withValues(alpha: 0.35);
    final backgroundColor = isHighlighted
        ? theme.colorScheme.primary.withValues(alpha: 0.06)
        : theme.colorScheme.surface;

    return Container(
      padding: EdgeInsets.all(spacing.lg),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: isHighlighted ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recommendedLabel != null) ...[
            Container(
              margin: EdgeInsets.only(bottom: spacing.md),
              padding: EdgeInsets.symmetric(
                horizontal: spacing.sm,
                vertical: spacing.xs,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                recommendedLabel!,
                style: typography.caption.copyWith(
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
          Text(
            title,
            style: typography.panelTitle.copyWith(fontWeight: FontWeight.bold),
          ),
          SizedBox(height: spacing.sm),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: spacing.sm - 2,
            children: [
              Text(
                price,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                period,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Text(description, style: typography.body),
          SizedBox(height: spacing.md),
          ...features.map(
            (feature) => Padding(
              padding: EdgeInsets.only(bottom: spacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    CupertinoIcons.checkmark_circle_fill,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(child: Text(feature, style: typography.bodyMuted)),
                ],
              ),
            ),
          ),
          SizedBox(height: spacing.sm),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: buttonText,
              variant: isHighlighted
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              onPressed: onTap,
            ),
          ),
        ],
      ),
    );
  }
}

class LicenseKeySuffixFormatter extends TextInputFormatter {
  static const String _prefix = 'CLINGFY-';
  static final RegExp _allowedChars = RegExp(r'[A-Z0-9]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // 1) Normalize case
    var text = newValue.text.toUpperCase();

    // 2) Remove visible/full prefix if pasted
    if (text.startsWith(_prefix)) {
      text = text.substring(_prefix.length);
    }

    // Also handle accidental duplicate prefix paste like:
    // CLINGFY-CLINGFY-B9E6...
    while (text.startsWith(_prefix)) {
      text = text.substring(_prefix.length);
    }

    // 3) Keep only alphanumeric chars (remove dashes first, then rebuild them)
    final raw = text.split('').where((c) => _allowedChars.hasMatch(c)).join();

    // Optional max length for suffix raw chars: 12 => XXXX-XXXX-XXXX
    final truncated = raw.length > 12 ? raw.substring(0, 12) : raw;

    // 4) Re-insert dash after every 4 chars
    final buffer = StringBuffer();
    for (int i = 0; i < truncated.length; i++) {
      if (i > 0 && i % 4 == 0) {
        buffer.write('-');
      }
      buffer.write(truncated[i]);
    }
    final formatted = buffer.toString();

    // Keep the caret at the end after reformatting.
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
