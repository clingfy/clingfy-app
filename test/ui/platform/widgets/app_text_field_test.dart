import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_text_field.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTextFieldApp() {
    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => MacosTheme(
        data: buildMacosTheme(Theme.of(context).brightness),
        child: child!,
      ),
      home: Scaffold(
        body: Center(child: AppTextField(controller: TextEditingController())),
      ),
    );
  }

  testWidgets('AppTextField uses the shared dark control fill on macOS', (
    tester,
  ) async {
    await tester.pumpWidget(buildTextFieldApp());
    await tester.pumpAndSettle();

    if (!isMac()) {
      return;
    }

    final textField = tester.widget<MacosTextField>(
      find.byType(MacosTextField),
    );
    final decoration = textField.decoration!;
    final focusedDecoration = textField.focusedDecoration!;
    final enabledBorder = decoration.border! as Border;
    final focusBorder = focusedDecoration.border! as Border;

    expect(decoration.color, const Color(0xFF2A2D35));
    expect(enabledBorder.top.color, const Color(0xFF2E2E39));
    expect(focusBorder.top.color, clingfyBrandColor);
    expect(focusBorder.top.width, 1.4);
  });
}
