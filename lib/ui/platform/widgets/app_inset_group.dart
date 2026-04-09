import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart';

class AppInsetGroup extends StatelessWidget {
  const AppInsetGroup({
    super.key,
    required this.children,
    this.padding = AppSidebarTokens.insetPadding,
  });
  final double padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (padding != 0) {
      return Padding(
        padding: const EdgeInsets.all(AppSidebarTokens.insetPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
