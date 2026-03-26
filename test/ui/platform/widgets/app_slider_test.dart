import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildSliderApp({
    required double initialValue,
    ValueChanged<double>? onChanged,
    ValueChanged<double>? onChangeEnd,
    double min = 0,
    double max = 1,
    int? divisions,
  }) {
    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => MacosTheme(
        data: buildMacosTheme(Theme.of(context).brightness),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            child: _SliderHarness(
              initialValue: initialValue,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'AppSlider uses the shared dark thumb and inactive track styling',
    (tester) async {
      await tester.pumpWidget(
        buildSliderApp(initialValue: 0.5, onChanged: (_) {}),
      );
      await tester.pumpAndSettle();

      if (!isMac()) {
        return;
      }

      final inactiveTrack = tester.widget<Container>(
        find.byKey(const Key('app_slider_inactive_track')),
      );
      final thumb = tester.widget<Container>(
        find.byKey(const Key('app_slider_thumb')),
      );
      final inactiveTrackDecoration =
          inactiveTrack.decoration! as BoxDecoration;
      final thumbDecoration = thumb.decoration! as BoxDecoration;

      expect(inactiveTrackDecoration.color, const Color(0xFF2A2D35));
      expect(thumbDecoration.color, Colors.white);
      expect(
        tester.getSize(find.byKey(const Key('app_slider_thumb'))).width,
        10,
      );
    },
  );

  testWidgets('AppSlider emits change and end callbacks from pointer input', (
    tester,
  ) async {
    final changed = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      buildSliderApp(
        initialValue: 0.2,
        onChanged: changed.add,
        onChangeEnd: ended.add,
      ),
    );
    await tester.pumpAndSettle();

    final sliderRect = tester.getRect(find.byType(AppSlider));
    final gesture = await tester.startGesture(
      Offset(sliderRect.left + 20, sliderRect.center.dy),
    );
    await tester.pump();
    await gesture.moveTo(Offset(sliderRect.right - 20, sliderRect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(changed, isNotEmpty);
    expect(ended, hasLength(1));
    expect(ended.single, closeTo(changed.last, 0.0001));
    expect(changed.last, greaterThan(0.2));
  });

  testWidgets('AppSlider disables interaction when onChanged is null', (
    tester,
  ) async {
    final ended = <double>[];

    await tester.pumpWidget(
      buildSliderApp(
        initialValue: 0.5,
        onChanged: null,
        onChangeEnd: ended.add,
      ),
    );
    await tester.pumpAndSettle();

    final sliderRect = tester.getRect(find.byType(AppSlider));
    final gesture = await tester.startGesture(
      Offset(sliderRect.left + 20, sliderRect.center.dy),
    );
    await tester.pump();
    await gesture.moveTo(Offset(sliderRect.right - 20, sliderRect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(ended, isEmpty);

    if (isMac()) {
      final disabledOpacity = find.descendant(
        of: find.byType(AppSlider),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Opacity && (widget.opacity - 0.55).abs() < 0.0001,
        ),
      );
      final disabledIgnorePointer = find.descendant(
        of: find.byType(AppSlider),
        matching: find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
      );

      expect(disabledOpacity, findsOneWidget);
      expect(disabledIgnorePointer, findsOneWidget);
    }
  });

  testWidgets('AppSlider quantizes divided values across drag updates', (
    tester,
  ) async {
    final changed = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      buildSliderApp(
        initialValue: 0,
        min: 0,
        max: 100,
        divisions: 4,
        onChanged: changed.add,
        onChangeEnd: ended.add,
      ),
    );
    await tester.pumpAndSettle();

    final sliderRect = tester.getRect(find.byType(AppSlider));
    final gesture = await tester.startGesture(
      Offset(sliderRect.left + 20, sliderRect.center.dy),
    );
    await tester.pump();

    for (final offset in const [12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0]) {
      await gesture.moveBy(Offset(offset, 0));
      await tester.pump();
    }

    await gesture.up();
    await tester.pumpAndSettle();

    expect(changed.length, greaterThan(2));
    expect(changed.every((value) => _isStepValue(value, 25)), isTrue);
    expect(ended, hasLength(1));
    expect(_isStepValue(ended.single, 25), isTrue);
  });
}

class _SliderHarness extends StatefulWidget {
  const _SliderHarness({
    required this.initialValue,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double initialValue;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_SliderHarness> createState() => _SliderHarnessState();
}

class _SliderHarnessState extends State<_SliderHarness> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  void _handleChanged(double value) {
    setState(() => _value = value);
    widget.onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSlider(
      value: _value,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      onChanged: widget.onChanged == null ? null : _handleChanged,
      onChangeEnd: widget.onChangeEnd,
    );
  }
}

bool _isStepValue(double value, double step) {
  final remainder = value % step;
  return remainder.abs() < 0.0001 || (step - remainder).abs() < 0.0001;
}
