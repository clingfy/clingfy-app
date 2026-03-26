import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> confirmResetPreferences(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await AppDialog.confirm(
    context,
    title: l10n.debugResetPreferencesTitle,
    message: l10n.debugResetPreferencesMessage,
    confirmLabel: l10n.debugResetPreferencesConfirm,
    cancelLabel: l10n.cancel,
  );

  if (result != true) {
    return;
  }

  Log.i('HomeShell', 'Resetting preferences');
  final sharedPreferences = await SharedPreferences.getInstance();
  await sharedPreferences.clear();
}
