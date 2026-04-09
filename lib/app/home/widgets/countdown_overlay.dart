import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';

class CountdownOverlay extends StatelessWidget {
  const CountdownOverlay({
    super.key,
    required this.controller,
    required this.onCancel,
  });

  final CountdownController controller;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isActive) {
          return const SizedBox.shrink();
        }

        return Container(
          color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.5),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${controller.remaining}',
                style: const TextStyle(
                  fontSize: 120,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                AppLocalizations.of(context)!.escToCancel,
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onCancel,
                child: Text(AppLocalizations.of(context)!.cancel),
              ),
            ],
          ),
        );
      },
    );
  }
}
