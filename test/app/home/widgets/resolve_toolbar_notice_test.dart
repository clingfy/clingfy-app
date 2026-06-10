import 'package:clingfy/app/home/home_error_mapper.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/widgets/desktop_toolbar.dart';
import 'package:clingfy/app/home/widgets/home_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 10.2: pins the toolbar notice precedence — the join where a coded
/// Windows recordingWarning either becomes the localized mapped toast or
/// falls back to the verbatim native message. (Pure helper, no widget
/// tree: home_toolbar_test.dart's harness is part of the pre-existing
/// FluentLocalizations breakage.)
void main() {
  ToolbarMessageAction action(void Function() onPressed) =>
      ToolbarMessageAction(label: 'Open Settings', onPressed: onPressed);

  test('known warning code renders the mapped message, warning tone, and '
      'the mapper action, dismissed via the notice', () {
    var dismissed = false;
    var actionPressed = false;
    final presentation = resolveToolbarNotice(
      notice: const HomeUiNotice(
        message: 'native english fallback',
        rawErrorCode: 'MIC_DISCONNECTED',
        tone: HomeUiNoticeTone.warning,
      ),
      // The mapper recognized the code: its message differs from the code.
      mapped: HomeErrorPresentation(
        message: 'Localized mic-disconnected toast',
        action: action(() => actionPressed = true),
      ),
      onDismissNotice: () => dismissed = true,
      onClearMessage: () => fail('coded notices dismiss via the notice'),
    );

    expect(presentation, isNotNull);
    expect(presentation!.message, 'Localized mic-disconnected toast');
    expect(presentation.tone, ToolbarMessageTone.warning);
    expect(presentation.action, isNotNull);
    presentation.action!.onPressed();
    expect(actionPressed, isTrue);
    presentation.onDismiss?.call();
    expect(dismissed, isTrue);
  });

  test('unknown warning code falls back to the verbatim native message', () {
    final presentation = resolveToolbarNotice(
      notice: const HomeUiNotice(
        message: 'native english fallback',
        rawErrorCode: 'FUTURE_UNKNOWN_CODE',
        tone: HomeUiNoticeTone.warning,
      ),
      // Mapper default branch echoes the raw code — the "unrecognized"
      // signal the precedence relies on.
      mapped: const HomeErrorPresentation(
        message: 'FUTURE_UNKNOWN_CODE',
        action: null,
      ),
      onDismissNotice: () {},
      onClearMessage: () {},
    );

    expect(presentation, isNotNull);
    expect(presentation!.message, 'native english fallback');
    expect(presentation.tone, ToolbarMessageTone.warning);
    expect(presentation.action, isNull);
  });

  test('message-only notice (macOS warning) keeps verbatim behavior', () {
    final presentation = resolveToolbarNotice(
      notice: const HomeUiNotice(
        message: 'macOS localized warning',
        tone: HomeUiNoticeTone.warning,
      ),
      mapped: const HomeErrorPresentation(message: null, action: null),
      onDismissNotice: () {},
      onClearMessage: () {},
    );

    expect(presentation!.message, 'macOS localized warning');
    expect(presentation.tone, ToolbarMessageTone.warning);
    expect(presentation.action, isNull);
  });

  test('no notice: mapped raw error renders error tone, cleared via '
      'onClearMessage', () {
    var cleared = false;
    final presentation = resolveToolbarNotice(
      notice: null,
      mapped: const HomeErrorPresentation(
        message: 'Recording already in progress.',
        action: null,
      ),
      onDismissNotice: () => fail('raw errors clear via onClearMessage'),
      onClearMessage: () => cleared = true,
    );

    expect(presentation!.message, 'Recording already in progress.');
    expect(presentation.tone, ToolbarMessageTone.error);
    presentation.onDismiss?.call();
    expect(cleared, isTrue);
  });

  test('nothing to show returns null', () {
    expect(
      resolveToolbarNotice(
        notice: null,
        mapped: const HomeErrorPresentation(message: null, action: null),
        onDismissNotice: () {},
        onClearMessage: () {},
      ),
      isNull,
    );
  });
}
