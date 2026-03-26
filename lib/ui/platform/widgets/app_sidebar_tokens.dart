import 'package:flutter/material.dart';
import 'package:clingfy/ui/theme/app_theme.dart';

/// Shared design tokens for desktop sidebars.
///
/// These values intentionally keep spacing and typography compact so complex
/// settings panels feel native and readable on desktop.
abstract final class AppSidebarTokens {
  static const double sectionGap = 12;
  static const double rowGap = 8;
  static const double compactGap = 4;
  static const double compactRowGap = 4;
  static const double controlGap = 10;
  static const double dropdownSectionTitleGap = 12;
  static const double contentHorizontalPadding = 12;
  static const double headerTopPadding = 12;
  static const double headerBottomPadding = 10;
  static const double headerContentGap = 12;
  static const double railWidth = 58;
  static const double railItemGap = 12;
  static const double railItemVerticalPadding = 6;

  static const double labelWidth = 164;
  static const double stackBreakpoint = 520;

  static const double controlMinWidth = 220;
  static const double controlMaxWidth = 360;
  static const double controlHeightMac = 32;
  static const double controlHeightDefault = 34;
  static const double compactButtonHeight = 32;

  static TextStyle rowTitleStyle(ThemeData theme) {
    return theme.appTypography.rowLabel.copyWith(
      color: theme.colorScheme.onSurface,
    );
  }

  static TextStyle helperStyle(ThemeData theme) {
    return theme.appTypography.bodyMuted.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  static TextStyle valueStyle(ThemeData theme) {
    return theme.appTypography.value.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  static TextStyle sectionHeaderStyle(ThemeData theme) {
    return theme.appTypography.sectionEyebrow.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  static TextStyle railLabelStyle(ThemeData theme, {required bool selected}) {
    return theme.appTypography.caption.copyWith(
      color: selected
          ? theme.colorScheme.onSurface
          : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.78),
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      height: 1.2,
    );
  }

  static TextStyle warningStyle(ThemeData theme) {
    return theme.appTypography.bodyMuted.copyWith(
      color: theme.colorScheme.error,
      fontWeight: FontWeight.w500,
    );
  }
}
