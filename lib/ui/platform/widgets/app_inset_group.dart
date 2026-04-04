import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart';

class AppInsetGroup extends StatelessWidget {
  const AppInsetGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSidebarTokens.insetPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
