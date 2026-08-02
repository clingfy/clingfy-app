import 'package:clingfy/app/infrastructure/observability/sentry_setup.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Sentry release tag is how a crash report maps back to a build.
///
/// Windows shipped for months tagging every build `clingfy@++<commit>` — the
/// release lane never passed FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER as
/// dart-defines, so both were empty. Sentry accepted it, the app worked, and
/// nothing anywhere failed. It was found by reading the release list by hand.
///
/// These exist so that cannot happen silently twice.
void main() {
  group('release tag format', () {
    // The contract, identical on macOS and Windows: version + build + commit.
    // Both platforms feed the same three dart-defines, so a report from either
    // maps back to an exact build.
    test('is clingfy@<version>+<build>+<commit>', () {
      expect(
        SentrySetup.buildSentryRelease(
          buildName: '1.0.6',
          buildNumber: '7',
          commitHash: 'ab92530',
        ),
        'clingfy@1.0.6+7+ab92530',
      );
    });

    // Real observed values from both platforms, to pin that one format serves
    // both — macOS build numbers are large (CI counter), Windows small.
    test('matches what both platforms actually publish', () {
      expect(
        SentrySetup.buildSentryRelease(
          buildName: '1.0.6',
          buildNumber: '619',
          commitHash: '8cdda45',
        ),
        'clingfy@1.0.6+619+8cdda45',
      );
    });

    // A local build with no git context is a real, tolerable case: drop the
    // commit rather than inventing one.
    test('drops the commit when it is absent', () {
      expect(
        SentrySetup.buildSentryRelease(
          buildName: '1.0.6',
          buildNumber: '7',
          commitHash: '',
        ),
        'clingfy@1.0.6+7',
      );
    });

    // 'unknown' is what the build scripts emit when `git rev-parse` fails. It
    // is not a commit, and pinning Sentry to a release literally named
    // "...+unknown" would be worse than having no commit at all.
    test('treats "unknown" as no commit rather than as a commit', () {
      expect(
        SentrySetup.buildSentryRelease(
          buildName: '1.0.6',
          buildNumber: '7',
          commitHash: 'unknown',
        ),
        'clingfy@1.0.6+7',
      );
    });
  });

  group('completeness detection', () {
    test('a full tag is complete', () {
      expect(
        SentrySetup.isReleaseTagComplete(buildName: '1.0.6', buildNumber: '7'),
        isTrue,
      );
    });

    // THE REGRESSION. Empty name and number produced `clingfy@++<commit>` on
    // every Windows build that shipped before the defines were passed.
    test('the exact shape that shipped broken is detected as incomplete', () {
      expect(
        SentrySetup.isReleaseTagComplete(buildName: '', buildNumber: ''),
        isFalse,
      );
      // and the string it produced, for the record
      expect(
        SentrySetup.buildSentryRelease(
          buildName: '',
          buildNumber: '',
          commitHash: '0b2a4af',
        ),
        'clingfy@++0b2a4af',
      );
    });

    test('either half missing is incomplete', () {
      expect(
        SentrySetup.isReleaseTagComplete(buildName: '1.0.6', buildNumber: ''),
        isFalse,
      );
      expect(
        SentrySetup.isReleaseTagComplete(buildName: '', buildNumber: '7'),
        isFalse,
      );
    });

    // A define set to whitespace is the same failure wearing a disguise: the
    // tag looks populated in a diff and identifies nothing.
    test('whitespace does not count as a version', () {
      expect(
        SentrySetup.isReleaseTagComplete(buildName: '  ', buildNumber: '7'),
        isFalse,
      );
      expect(
        SentrySetup.isReleaseTagComplete(buildName: '1.0.6', buildNumber: ' '),
        isFalse,
      );
    });
  });
}
