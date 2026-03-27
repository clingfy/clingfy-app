import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_ro.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('ro'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Clingfy — Screen Recorder'**
  String get appTitle;

  /// No description provided for @record.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get record;

  /// No description provided for @output.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get output;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @tabScreenAudio.
  ///
  /// In en, this message translates to:
  /// **'Screen & Audio'**
  String get tabScreenAudio;

  /// No description provided for @tabFaceCam.
  ///
  /// In en, this message translates to:
  /// **'Face Cam'**
  String get tabFaceCam;

  /// No description provided for @screenTarget.
  ///
  /// In en, this message translates to:
  /// **'Screen target'**
  String get screenTarget;

  /// No description provided for @recordTarget.
  ///
  /// In en, this message translates to:
  /// **'Record target'**
  String get recordTarget;

  /// No description provided for @chosenScreen.
  ///
  /// In en, this message translates to:
  /// **'Chosen screen'**
  String get chosenScreen;

  /// No description provided for @appWindowScreen.
  ///
  /// In en, this message translates to:
  /// **'App window’s screen'**
  String get appWindowScreen;

  /// No description provided for @specificAppWindow.
  ///
  /// In en, this message translates to:
  /// **'Specific app window'**
  String get specificAppWindow;

  /// No description provided for @screenUnderMouse.
  ///
  /// In en, this message translates to:
  /// **'Screen under mouse (at start)'**
  String get screenUnderMouse;

  /// No description provided for @followMouse.
  ///
  /// In en, this message translates to:
  /// **'Follow mouse (splits files)'**
  String get followMouse;

  /// No description provided for @followMouseNote.
  ///
  /// In en, this message translates to:
  /// **'Note: with the current encoder, the recording will split when the mouse moves to another display.'**
  String get followMouseNote;

  /// No description provided for @display.
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get display;

  /// No description provided for @refreshDisplays.
  ///
  /// In en, this message translates to:
  /// **'Refresh displays (⌘R)'**
  String get refreshDisplays;

  /// No description provided for @screenToRecord.
  ///
  /// In en, this message translates to:
  /// **'Screen to record'**
  String get screenToRecord;

  /// No description provided for @mainDisplay.
  ///
  /// In en, this message translates to:
  /// **'Main display'**
  String get mainDisplay;

  /// No description provided for @appWindow.
  ///
  /// In en, this message translates to:
  /// **'App window'**
  String get appWindow;

  /// No description provided for @refreshWindows.
  ///
  /// In en, this message translates to:
  /// **'Refresh windows'**
  String get refreshWindows;

  /// No description provided for @windowToRecord.
  ///
  /// In en, this message translates to:
  /// **'Window to record'**
  String get windowToRecord;

  /// No description provided for @selectAppWindow.
  ///
  /// In en, this message translates to:
  /// **'Select an app window'**
  String get selectAppWindow;

  /// No description provided for @refreshWindowHint.
  ///
  /// In en, this message translates to:
  /// **'Refresh if you don’t see your window, then select it above.'**
  String get refreshWindowHint;

  /// No description provided for @areaRecording.
  ///
  /// In en, this message translates to:
  /// **'Area recording'**
  String get areaRecording;

  /// No description provided for @pickArea.
  ///
  /// In en, this message translates to:
  /// **'Pick area...'**
  String get pickArea;

  /// No description provided for @changeArea.
  ///
  /// In en, this message translates to:
  /// **'Change area'**
  String get changeArea;

  /// No description provided for @revealArea.
  ///
  /// In en, this message translates to:
  /// **'Reveal'**
  String get revealArea;

  /// No description provided for @clearArea.
  ///
  /// In en, this message translates to:
  /// **'Delete image'**
  String get clearArea;

  /// No description provided for @areaRecordingHelper.
  ///
  /// In en, this message translates to:
  /// **'Record a custom rectangular area of the screen.'**
  String get areaRecordingHelper;

  /// No description provided for @noAreaSelected.
  ///
  /// In en, this message translates to:
  /// **'No area selected'**
  String get noAreaSelected;

  /// No description provided for @selectedAreaAt.
  ///
  /// In en, this message translates to:
  /// **'Display {id}: {width}x{height} at ({x}, {y})'**
  String selectedAreaAt(
    Object height,
    Object id,
    Object width,
    Object x,
    Object y,
  );

  /// No description provided for @audio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audio;

  /// No description provided for @refreshAudio.
  ///
  /// In en, this message translates to:
  /// **'Refresh audio devices (⌘R)'**
  String get refreshAudio;

  /// No description provided for @inputDevice.
  ///
  /// In en, this message translates to:
  /// **'Input device'**
  String get inputDevice;

  /// No description provided for @noAudio.
  ///
  /// In en, this message translates to:
  /// **'No audio'**
  String get noAudio;

  /// No description provided for @camera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// No description provided for @refreshCameras.
  ///
  /// In en, this message translates to:
  /// **'Refresh cameras (⌘R)'**
  String get refreshCameras;

  /// No description provided for @cameraDevice.
  ///
  /// In en, this message translates to:
  /// **'Camera device'**
  String get cameraDevice;

  /// No description provided for @recordingQuality.
  ///
  /// In en, this message translates to:
  /// **'Recording quality'**
  String get recordingQuality;

  /// No description provided for @resolution.
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get resolution;

  /// No description provided for @frameRate.
  ///
  /// In en, this message translates to:
  /// **'Frame Rate'**
  String get frameRate;

  /// No description provided for @fps.
  ///
  /// In en, this message translates to:
  /// **'{value} FPS'**
  String fps(Object value);

  /// No description provided for @saveLocation.
  ///
  /// In en, this message translates to:
  /// **'Save location'**
  String get saveLocation;

  /// No description provided for @format.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get format;

  /// No description provided for @codec.
  ///
  /// In en, this message translates to:
  /// **'Codec'**
  String get codec;

  /// No description provided for @bitrate.
  ///
  /// In en, this message translates to:
  /// **'Bitrate'**
  String get bitrate;

  /// No description provided for @hevc.
  ///
  /// In en, this message translates to:
  /// **'HEVC (H.265)'**
  String get hevc;

  /// No description provided for @h264.
  ///
  /// In en, this message translates to:
  /// **'H.264'**
  String get h264;

  /// No description provided for @auto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get auto;

  /// No description provided for @low.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get low;

  /// No description provided for @medium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get medium;

  /// No description provided for @high.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get high;

  /// No description provided for @original.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get original;

  /// No description provided for @uhd2k.
  ///
  /// In en, this message translates to:
  /// **'2K (1440P)'**
  String get uhd2k;

  /// No description provided for @uhd4k.
  ///
  /// In en, this message translates to:
  /// **'4K (2160P)'**
  String get uhd4k;

  /// No description provided for @uhd8k.
  ///
  /// In en, this message translates to:
  /// **'8K (4320P)'**
  String get uhd8k;

  /// No description provided for @revealInFinder.
  ///
  /// In en, this message translates to:
  /// **'Reveal in Finder'**
  String get revealInFinder;

  /// No description provided for @resetToDefault.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get resetToDefault;

  /// No description provided for @openFolder.
  ///
  /// In en, this message translates to:
  /// **'Open Folder'**
  String get openFolder;

  /// No description provided for @recordingHighlight.
  ///
  /// In en, this message translates to:
  /// **'Glow when recording'**
  String get recordingHighlight;

  /// No description provided for @recordingGlowStrength.
  ///
  /// In en, this message translates to:
  /// **'Glow strength'**
  String get recordingGlowStrength;

  /// No description provided for @recordingGlowStrengthPercent.
  ///
  /// In en, this message translates to:
  /// **'Glow strength: {value}%'**
  String recordingGlowStrengthPercent(Object value);

  /// No description provided for @chooseSaveFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose save folder…'**
  String get chooseSaveFolder;

  /// No description provided for @defaultSaveFolder.
  ///
  /// In en, this message translates to:
  /// **'Default: ~/Movies/Clingfy'**
  String get defaultSaveFolder;

  /// No description provided for @duration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// No description provided for @autoStopAfter.
  ///
  /// In en, this message translates to:
  /// **'Auto-stop after'**
  String get autoStopAfter;

  /// No description provided for @preset.
  ///
  /// In en, this message translates to:
  /// **'Preset'**
  String get preset;

  /// No description provided for @customMinutes.
  ///
  /// In en, this message translates to:
  /// **'Custom (minutes)'**
  String get customMinutes;

  /// No description provided for @forceLetterbox.
  ///
  /// In en, this message translates to:
  /// **'Force 16:9 (letterbox)'**
  String get forceLetterbox;

  /// No description provided for @forceLetterboxSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Centers your screen in a 16:9 canvas (e.g., 1080p) with black padding.'**
  String get forceLetterboxSubtitle;

  /// No description provided for @forceLetterboxHint.
  ///
  /// In en, this message translates to:
  /// **'Fixes pillarboxing on YouTube when your screen is ultra-wide or not 16:9.'**
  String get forceLetterboxHint;

  /// No description provided for @appSettings.
  ///
  /// In en, this message translates to:
  /// **'App Settings'**
  String get appSettings;

  /// No description provided for @appSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage workspace preferences, shortcuts, license status, diagnostics, and app details.'**
  String get appSettingsDescription;

  /// No description provided for @openAppSettings.
  ///
  /// In en, this message translates to:
  /// **'Open App Settings'**
  String get openAppSettings;

  /// No description provided for @overlayFaceCam.
  ///
  /// In en, this message translates to:
  /// **'Overlay (Face-cam)'**
  String get overlayFaceCam;

  /// No description provided for @overlayFaceCamVisibility.
  ///
  /// In en, this message translates to:
  /// **'Face-cam visibility'**
  String get overlayFaceCamVisibility;

  /// No description provided for @visibility.
  ///
  /// In en, this message translates to:
  /// **'Visibility'**
  String get visibility;

  /// No description provided for @overlayHint.
  ///
  /// In en, this message translates to:
  /// **'Overlay will appear when recording starts.'**
  String get overlayHint;

  /// No description provided for @recordingIndicator.
  ///
  /// In en, this message translates to:
  /// **'Recording indicator'**
  String get recordingIndicator;

  /// No description provided for @showIndicator.
  ///
  /// In en, this message translates to:
  /// **'Show recording indicator'**
  String get showIndicator;

  /// No description provided for @pinToTopRight.
  ///
  /// In en, this message translates to:
  /// **'Pin to top-right'**
  String get pinToTopRight;

  /// No description provided for @indicatorHint.
  ///
  /// In en, this message translates to:
  /// **'A small “REC” dot appears while recording. When pinned, it stays in the top-right; otherwise you can drag it.'**
  String get indicatorHint;

  /// No description provided for @cursorHighlight.
  ///
  /// In en, this message translates to:
  /// **'Cursor highlight'**
  String get cursorHighlight;

  /// No description provided for @cursorHighlightVisibility.
  ///
  /// In en, this message translates to:
  /// **'Cursor highlight visibility'**
  String get cursorHighlightVisibility;

  /// No description provided for @cursorHint.
  ///
  /// In en, this message translates to:
  /// **'Cursor highlight is active only when recording.'**
  String get cursorHint;

  /// No description provided for @appTitleFull.
  ///
  /// In en, this message translates to:
  /// **'Clingfy — Screen Recorder'**
  String get appTitleFull;

  /// No description provided for @recordingPathCopied.
  ///
  /// In en, this message translates to:
  /// **'Recording path copied'**
  String get recordingPathCopied;

  /// No description provided for @grantAccessibilityPermission.
  ///
  /// In en, this message translates to:
  /// **'Grant Accessibility permission to highlight the cursor.'**
  String get grantAccessibilityPermission;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @exporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting...'**
  String get exporting;

  /// No description provided for @paywallTitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock Pro exports'**
  String get paywallTitle;

  /// No description provided for @paywallSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Upgrade your plan or activate a license key to continue exporting.'**
  String get paywallSubtitle;

  /// No description provided for @paywallTrialRemaining.
  ///
  /// In en, this message translates to:
  /// **'Trial exports remaining: {count}'**
  String paywallTrialRemaining(int count);

  /// No description provided for @paywallTrialTier.
  ///
  /// In en, this message translates to:
  /// **'Trial plan: limited exports to test features'**
  String get paywallTrialTier;

  /// No description provided for @paywallLifetimeTier.
  ///
  /// In en, this message translates to:
  /// **'Lifetime plan: one-time purchase with update coverage'**
  String get paywallLifetimeTier;

  /// No description provided for @paywallSubscriptionTier.
  ///
  /// In en, this message translates to:
  /// **'Subscription plan: ongoing access and updates'**
  String get paywallSubscriptionTier;

  /// No description provided for @paywallAlreadyHaveKey.
  ///
  /// In en, this message translates to:
  /// **'Already have a key?'**
  String get paywallAlreadyHaveKey;

  /// No description provided for @paywallLicenseKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Enter license key'**
  String get paywallLicenseKeyHint;

  /// No description provided for @paywallLicenseKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a license key.'**
  String get paywallLicenseKeyRequired;

  /// No description provided for @paywallActivateKey.
  ///
  /// In en, this message translates to:
  /// **'Activate key'**
  String get paywallActivateKey;

  /// No description provided for @paywallActivationFailed.
  ///
  /// In en, this message translates to:
  /// **'License activation failed.'**
  String get paywallActivationFailed;

  /// No description provided for @paywallExportBlocked.
  ///
  /// In en, this message translates to:
  /// **'Export is locked. Upgrade or activate a key to continue.'**
  String get paywallExportBlocked;

  /// No description provided for @paywallConsumeFailed.
  ///
  /// In en, this message translates to:
  /// **'Export succeeded, but trial credit sync failed. Check your connection.'**
  String get paywallConsumeFailed;

  /// No description provided for @paywallSubtitleStarter.
  ///
  /// In en, this message translates to:
  /// **'Get unlimited exports, no watermark, and full Pro features.'**
  String get paywallSubtitleStarter;

  /// No description provided for @paywallSubtitleTrial.
  ///
  /// In en, this message translates to:
  /// **'You have {count} free exports remaining. Upgrade to remove limits.'**
  String paywallSubtitleTrial(int count);

  /// No description provided for @paywallCardMonthlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Pro Monthly'**
  String get paywallCardMonthlyTitle;

  /// No description provided for @paywallCardMonthlyPrice.
  ///
  /// In en, this message translates to:
  /// **'\$9.99'**
  String get paywallCardMonthlyPrice;

  /// No description provided for @paywallCardMonthlyPeriod.
  ///
  /// In en, this message translates to:
  /// **'/ month'**
  String get paywallCardMonthlyPeriod;

  /// No description provided for @paywallCardMonthlyDescription.
  ///
  /// In en, this message translates to:
  /// **'Always get the latest features.'**
  String get paywallCardMonthlyDescription;

  /// No description provided for @paywallCardMonthlyFeature1.
  ///
  /// In en, this message translates to:
  /// **'Unlimited exports'**
  String get paywallCardMonthlyFeature1;

  /// No description provided for @paywallCardMonthlyFeature2.
  ///
  /// In en, this message translates to:
  /// **'No watermark'**
  String get paywallCardMonthlyFeature2;

  /// No description provided for @paywallCardMonthlyFeature3.
  ///
  /// In en, this message translates to:
  /// **'Priority support'**
  String get paywallCardMonthlyFeature3;

  /// No description provided for @paywallCardMonthlyCta.
  ///
  /// In en, this message translates to:
  /// **'Subscribe'**
  String get paywallCardMonthlyCta;

  /// No description provided for @paywallCardLifetimeTitle.
  ///
  /// In en, this message translates to:
  /// **'Lifetime Pro'**
  String get paywallCardLifetimeTitle;

  /// No description provided for @paywallCardLifetimePrice.
  ///
  /// In en, this message translates to:
  /// **'\$59.99'**
  String get paywallCardLifetimePrice;

  /// No description provided for @paywallCardLifetimePeriod.
  ///
  /// In en, this message translates to:
  /// **'one-time'**
  String get paywallCardLifetimePeriod;

  /// No description provided for @paywallCardLifetimeDescription.
  ///
  /// In en, this message translates to:
  /// **'Own Clingfy forever + 1 year of updates.'**
  String get paywallCardLifetimeDescription;

  /// No description provided for @paywallCardLifetimeFeature1.
  ///
  /// In en, this message translates to:
  /// **'Permanent ownership'**
  String get paywallCardLifetimeFeature1;

  /// No description provided for @paywallCardLifetimeFeature2.
  ///
  /// In en, this message translates to:
  /// **'1-year updates included'**
  String get paywallCardLifetimeFeature2;

  /// No description provided for @paywallCardLifetimeFeature3.
  ///
  /// In en, this message translates to:
  /// **'Unlimited exports'**
  String get paywallCardLifetimeFeature3;

  /// No description provided for @paywallCardLifetimeFeature4.
  ///
  /// In en, this message translates to:
  /// **'No watermark'**
  String get paywallCardLifetimeFeature4;

  /// No description provided for @paywallCardLifetimeCta.
  ///
  /// In en, this message translates to:
  /// **'Buy Lifetime'**
  String get paywallCardLifetimeCta;

  /// No description provided for @paywallCardExtensionTitle.
  ///
  /// In en, this message translates to:
  /// **'Updates Extension'**
  String get paywallCardExtensionTitle;

  /// No description provided for @paywallCardExtensionPrice.
  ///
  /// In en, this message translates to:
  /// **'\$19.99'**
  String get paywallCardExtensionPrice;

  /// No description provided for @paywallCardExtensionPeriod.
  ///
  /// In en, this message translates to:
  /// **'one-time'**
  String get paywallCardExtensionPeriod;

  /// No description provided for @paywallCardExtensionDescription.
  ///
  /// In en, this message translates to:
  /// **'Extend updates eligibility by +12 months.'**
  String get paywallCardExtensionDescription;

  /// No description provided for @paywallCardExtensionFeature1.
  ///
  /// In en, this message translates to:
  /// **'Adds +12 months updates'**
  String get paywallCardExtensionFeature1;

  /// No description provided for @paywallCardExtensionFeature2.
  ///
  /// In en, this message translates to:
  /// **'Keep lifetime ownership'**
  String get paywallCardExtensionFeature2;

  /// No description provided for @paywallCardExtensionFeature3.
  ///
  /// In en, this message translates to:
  /// **'Works with existing key'**
  String get paywallCardExtensionFeature3;

  /// No description provided for @paywallCardExtensionCta.
  ///
  /// In en, this message translates to:
  /// **'Extend Updates'**
  String get paywallCardExtensionCta;

  /// No description provided for @paywallRecommendedBadge.
  ///
  /// In en, this message translates to:
  /// **'RECOMMENDED'**
  String get paywallRecommendedBadge;

  /// No description provided for @paywallActivationSuccess.
  ///
  /// In en, this message translates to:
  /// **'Pro unlocked successfully!'**
  String get paywallActivationSuccess;

  /// No description provided for @paywallPricingOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open pricing page.'**
  String get paywallPricingOpenFailed;

  /// No description provided for @licenseDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'License & Devices'**
  String get licenseDevicesTitle;

  /// No description provided for @licenseDevicesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage this Mac\'s license link for device transfer.'**
  String get licenseDevicesSubtitle;

  /// No description provided for @licensePlanLabel.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get licensePlanLabel;

  /// No description provided for @licenseDeviceLinked.
  ///
  /// In en, this message translates to:
  /// **'This device is linked to your license.'**
  String get licenseDeviceLinked;

  /// No description provided for @licenseDeviceNotLinked.
  ///
  /// In en, this message translates to:
  /// **'No active license is linked on this device.'**
  String get licenseDeviceNotLinked;

  /// No description provided for @licenseDeactivateButton.
  ///
  /// In en, this message translates to:
  /// **'Deactivate this device'**
  String get licenseDeactivateButton;

  /// No description provided for @licenseDeactivateConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Deactivate this device?'**
  String get licenseDeactivateConfirmTitle;

  /// No description provided for @licenseDeactivateConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This will unlink the current Mac from your license key on the server.'**
  String get licenseDeactivateConfirmBody;

  /// No description provided for @licenseDeactivateConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Deactivate'**
  String get licenseDeactivateConfirmAction;

  /// No description provided for @licenseDeactivateSuccess.
  ///
  /// In en, this message translates to:
  /// **'Device deactivated successfully.'**
  String get licenseDeactivateSuccess;

  /// No description provided for @licenseDeactivateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not deactivate this device right now.'**
  String get licenseDeactivateFailed;

  /// No description provided for @licenseDeactivateUnavailable.
  ///
  /// In en, this message translates to:
  /// **'License could not be found on the server.'**
  String get licenseDeactivateUnavailable;

  /// No description provided for @licenseStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Plan & Entitlement'**
  String get licenseStatusTitle;

  /// No description provided for @licenseStatusEntitled.
  ///
  /// In en, this message translates to:
  /// **'Pro features unlocked'**
  String get licenseStatusEntitled;

  /// No description provided for @licenseStatusNotEntitled.
  ///
  /// In en, this message translates to:
  /// **'Pro features locked'**
  String get licenseStatusNotEntitled;

  /// No description provided for @licenseUpdatesCovered.
  ///
  /// In en, this message translates to:
  /// **'Updates covered'**
  String get licenseUpdatesCovered;

  /// No description provided for @licenseUpdatesExpired.
  ///
  /// In en, this message translates to:
  /// **'Updates not covered'**
  String get licenseUpdatesExpired;

  /// No description provided for @licenseActivateOrUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Activate key or upgrade'**
  String get licenseActivateOrUpgrade;

  /// No description provided for @licenseUpgradeToPro.
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Pro'**
  String get licenseUpgradeToPro;

  /// No description provided for @licenseActivateKeyOnly.
  ///
  /// In en, this message translates to:
  /// **'Activate license key'**
  String get licenseActivateKeyOnly;

  /// No description provided for @licenseExtendUpdates.
  ///
  /// In en, this message translates to:
  /// **'Extend updates'**
  String get licenseExtendUpdates;

  /// No description provided for @licenseSubscriptionActive.
  ///
  /// In en, this message translates to:
  /// **'Subscription active'**
  String get licenseSubscriptionActive;

  /// No description provided for @licenseLifetimeActive.
  ///
  /// In en, this message translates to:
  /// **'Lifetime license active'**
  String get licenseLifetimeActive;

  /// No description provided for @licenseActivateKeySecondary.
  ///
  /// In en, this message translates to:
  /// **'Have a key? Activate it'**
  String get licenseActivateKeySecondary;

  /// No description provided for @licenseSummaryHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'License summary'**
  String get licenseSummaryHeroTitle;

  /// No description provided for @licenseSummaryHeroSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your current plan, entitlement, and update coverage.'**
  String get licenseSummaryHeroSubtitle;

  /// No description provided for @licenseDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'License details'**
  String get licenseDetailsTitle;

  /// No description provided for @licenseDetailsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Identity and activation information for this device.'**
  String get licenseDetailsSubtitle;

  /// No description provided for @licenseActionTitle.
  ///
  /// In en, this message translates to:
  /// **'Next action'**
  String get licenseActionTitle;

  /// No description provided for @licenseActionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Recommended next step based on your current plan.'**
  String get licenseActionSubtitle;

  /// No description provided for @licenseKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'License key'**
  String get licenseKeyLabel;

  /// No description provided for @licenseMemberSince.
  ///
  /// In en, this message translates to:
  /// **'Member since'**
  String get licenseMemberSince;

  /// No description provided for @licenseActivatedOnThisDevice.
  ///
  /// In en, this message translates to:
  /// **'Activated on this device'**
  String get licenseActivatedOnThisDevice;

  /// No description provided for @licenseUpdatesUntil.
  ///
  /// In en, this message translates to:
  /// **'Updates covered until'**
  String get licenseUpdatesUntil;

  /// No description provided for @licenseLinkStatus.
  ///
  /// In en, this message translates to:
  /// **'Device link'**
  String get licenseLinkStatus;

  /// No description provided for @licenseSummaryStarter.
  ///
  /// In en, this message translates to:
  /// **'Activate a key or upgrade to unlock unlimited Pro exports.'**
  String get licenseSummaryStarter;

  /// No description provided for @licenseSummaryTrial.
  ///
  /// In en, this message translates to:
  /// **'You are using Trial with {count} exports remaining.'**
  String licenseSummaryTrial(int count);

  /// No description provided for @licenseSummarySubscriptionActive.
  ///
  /// In en, this message translates to:
  /// **'Your subscription is active and all current Pro features are unlocked.'**
  String get licenseSummarySubscriptionActive;

  /// No description provided for @licenseSummaryLifetimeCovered.
  ///
  /// In en, this message translates to:
  /// **'You own Clingfy Pro permanently and your update coverage is active.'**
  String get licenseSummaryLifetimeCovered;

  /// No description provided for @licenseSummaryLifetimeExpiringSoon.
  ///
  /// In en, this message translates to:
  /// **'Your lifetime license is active, but update coverage ends in {days} days.'**
  String licenseSummaryLifetimeExpiringSoon(int days);

  /// No description provided for @licenseSummaryLifetimeExpired.
  ///
  /// In en, this message translates to:
  /// **'Your lifetime license is active, but update coverage has expired.'**
  String get licenseSummaryLifetimeExpired;

  /// No description provided for @licensePlanTrial.
  ///
  /// In en, this message translates to:
  /// **'Trial'**
  String get licensePlanTrial;

  /// No description provided for @licensePlanLifetime.
  ///
  /// In en, this message translates to:
  /// **'Lifetime'**
  String get licensePlanLifetime;

  /// No description provided for @licensePlanSubscription.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get licensePlanSubscription;

  /// No description provided for @licensePlanStarter.
  ///
  /// In en, this message translates to:
  /// **'Starter'**
  String get licensePlanStarter;

  /// No description provided for @layoutSettings.
  ///
  /// In en, this message translates to:
  /// **'Layout Settings'**
  String get layoutSettings;

  /// No description provided for @effectsSettings.
  ///
  /// In en, this message translates to:
  /// **'Effects Settings'**
  String get effectsSettings;

  /// No description provided for @exportSettings.
  ///
  /// In en, this message translates to:
  /// **'Export Settings'**
  String get exportSettings;

  /// No description provided for @size.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get size;

  /// No description provided for @padding.
  ///
  /// In en, this message translates to:
  /// **'Padding'**
  String get padding;

  /// No description provided for @roundedCorners.
  ///
  /// In en, this message translates to:
  /// **'Rounded corners'**
  String get roundedCorners;

  /// No description provided for @backgroundImage.
  ///
  /// In en, this message translates to:
  /// **'Background Image'**
  String get backgroundImage;

  /// No description provided for @moreImages.
  ///
  /// In en, this message translates to:
  /// **'More images'**
  String get moreImages;

  /// No description provided for @pickAnImage.
  ///
  /// In en, this message translates to:
  /// **'Pick an image'**
  String get pickAnImage;

  /// No description provided for @backgroundColor.
  ///
  /// In en, this message translates to:
  /// **'Background Color'**
  String get backgroundColor;

  /// No description provided for @moreColors.
  ///
  /// In en, this message translates to:
  /// **'More colors'**
  String get moreColors;

  /// No description provided for @pickColor.
  ///
  /// In en, this message translates to:
  /// **'Pick a color'**
  String get pickColor;

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// No description provided for @showCursor.
  ///
  /// In en, this message translates to:
  /// **'Show Cursor'**
  String get showCursor;

  /// No description provided for @toggleCursorVisibility.
  ///
  /// In en, this message translates to:
  /// **'Toggle cursor visibility'**
  String get toggleCursorVisibility;

  /// No description provided for @cursorSize.
  ///
  /// In en, this message translates to:
  /// **'Cursor Size'**
  String get cursorSize;

  /// No description provided for @zoomInEffect.
  ///
  /// In en, this message translates to:
  /// **'Zoom in effect'**
  String get zoomInEffect;

  /// No description provided for @manageZoomEffects.
  ///
  /// In en, this message translates to:
  /// **'Manage zoom in effects'**
  String get manageZoomEffects;

  /// No description provided for @intensity.
  ///
  /// In en, this message translates to:
  /// **'Intensity'**
  String get intensity;

  /// No description provided for @layout.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get layout;

  /// No description provided for @effects.
  ///
  /// In en, this message translates to:
  /// **'Effects'**
  String get effects;

  /// No description provided for @refreshDevicesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh devices (⌘R)'**
  String get refreshDevicesTooltip;

  /// No description provided for @copyLastPathTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy last path'**
  String get copyLastPathTooltip;

  /// No description provided for @timeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get timeline;

  /// No description provided for @closeTimelineTooltip.
  ///
  /// In en, this message translates to:
  /// **'Close timeline'**
  String get closeTimelineTooltip;

  /// No description provided for @zoomAddSegment.
  ///
  /// In en, this message translates to:
  /// **'Add zoom segment'**
  String get zoomAddSegment;

  /// No description provided for @zoomAddOne.
  ///
  /// In en, this message translates to:
  /// **'Add one'**
  String get zoomAddOne;

  /// No description provided for @zoomKeepAdding.
  ///
  /// In en, this message translates to:
  /// **'Keep adding'**
  String get zoomKeepAdding;

  /// No description provided for @zoomKeepAddingTooltip.
  ///
  /// In en, this message translates to:
  /// **'Keep adding zoom segments'**
  String get zoomKeepAddingTooltip;

  /// No description provided for @zoomAddOneTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add one zoom segment'**
  String get zoomAddOneTooltip;

  /// No description provided for @zoomAddOneStatus.
  ///
  /// In en, this message translates to:
  /// **'Add one zoom • Drag on the zoom track • Esc to cancel'**
  String get zoomAddOneStatus;

  /// No description provided for @zoomKeepAddingStatus.
  ///
  /// In en, this message translates to:
  /// **'Keep adding zooms • Drag on the zoom track • Esc to exit'**
  String get zoomKeepAddingStatus;

  /// No description provided for @zoomMoveStatus.
  ///
  /// In en, this message translates to:
  /// **'Moving selected zoom'**
  String get zoomMoveStatus;

  /// No description provided for @zoomTrimStartStatus.
  ///
  /// In en, this message translates to:
  /// **'Trimming zoom start'**
  String get zoomTrimStartStatus;

  /// No description provided for @zoomTrimEndStatus.
  ///
  /// In en, this message translates to:
  /// **'Trimming zoom end'**
  String get zoomTrimEndStatus;

  /// No description provided for @zoomBandSelectStatus.
  ///
  /// In en, this message translates to:
  /// **'Selecting zooms'**
  String get zoomBandSelectStatus;

  /// No description provided for @zoomSelectionTools.
  ///
  /// In en, this message translates to:
  /// **'Selection tools'**
  String get zoomSelectionTools;

  /// No description provided for @zoomDeleteSelectedOne.
  ///
  /// In en, this message translates to:
  /// **'Delete selected segment'**
  String get zoomDeleteSelectedOne;

  /// No description provided for @zoomDeleteSelectedMany.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} segments'**
  String zoomDeleteSelectedMany(int count);

  /// No description provided for @zoomSelectAfterPlayhead.
  ///
  /// In en, this message translates to:
  /// **'Select after playhead'**
  String get zoomSelectAfterPlayhead;

  /// No description provided for @zoomClearSelection.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get zoomClearSelection;

  /// No description provided for @zoomSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String zoomSelectedCount(int count);

  /// No description provided for @zoomSelectAllVisible.
  ///
  /// In en, this message translates to:
  /// **'Select all visible'**
  String get zoomSelectAllVisible;

  /// No description provided for @zoomUndoLastAction.
  ///
  /// In en, this message translates to:
  /// **'Undo last action'**
  String get zoomUndoLastAction;

  /// No description provided for @zoomSelectionCleared.
  ///
  /// In en, this message translates to:
  /// **'Selection cleared'**
  String get zoomSelectionCleared;

  /// No description provided for @zoomChangeSelectionRange.
  ///
  /// In en, this message translates to:
  /// **'Change selection range'**
  String get zoomChangeSelectionRange;

  /// No description provided for @stopIn.
  ///
  /// In en, this message translates to:
  /// **'Stop in {value}'**
  String stopIn(Object value);

  /// No description provided for @recording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get recording;

  /// No description provided for @classic43.
  ///
  /// In en, this message translates to:
  /// **'Classic (4:3)'**
  String get classic43;

  /// No description provided for @square11.
  ///
  /// In en, this message translates to:
  /// **'Square (1:1)'**
  String get square11;

  /// No description provided for @youtube169.
  ///
  /// In en, this message translates to:
  /// **'YouTube (16:9)'**
  String get youtube169;

  /// No description provided for @reel916.
  ///
  /// In en, this message translates to:
  /// **'Reel (9:16)'**
  String get reel916;

  /// No description provided for @vertical4k.
  ///
  /// In en, this message translates to:
  /// **'Vertical 4K (2160x3840)'**
  String get vertical4k;

  /// No description provided for @canvasAspect.
  ///
  /// In en, this message translates to:
  /// **'Canvas Aspect'**
  String get canvasAspect;

  /// No description provided for @fitMode.
  ///
  /// In en, this message translates to:
  /// **'Fit Mode'**
  String get fitMode;

  /// No description provided for @fit.
  ///
  /// In en, this message translates to:
  /// **'Fit'**
  String get fit;

  /// No description provided for @fill.
  ///
  /// In en, this message translates to:
  /// **'Fill'**
  String get fill;

  /// No description provided for @recordingInProgress.
  ///
  /// In en, this message translates to:
  /// **'RECORDING IN PROGRESS'**
  String get recordingInProgress;

  /// No description provided for @recordingPaused.
  ///
  /// In en, this message translates to:
  /// **'RECORDING PAUSED'**
  String get recordingPaused;

  /// No description provided for @readyToRecord.
  ///
  /// In en, this message translates to:
  /// **'READY TO RECORD'**
  String get readyToRecord;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'PAUSE'**
  String get pause;

  /// No description provided for @resume.
  ///
  /// In en, this message translates to:
  /// **'RESUME'**
  String get resume;

  /// No description provided for @paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get paused;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'STOP'**
  String get stop;

  /// No description provided for @startRecording.
  ///
  /// In en, this message translates to:
  /// **'START RECORDING'**
  String get startRecording;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loading;

  /// No description provided for @hoursShort.
  ///
  /// In en, this message translates to:
  /// **'{value} h'**
  String hoursShort(Object value);

  /// No description provided for @minutesShort.
  ///
  /// In en, this message translates to:
  /// **'{value} min'**
  String minutesShort(Object value);

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @whileRecording.
  ///
  /// In en, this message translates to:
  /// **'While recording'**
  String get whileRecording;

  /// No description provided for @alwaysOn.
  ///
  /// In en, this message translates to:
  /// **'Always on'**
  String get alwaysOn;

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @settingsWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get settingsWorkspace;

  /// No description provided for @settingsWorkspaceDescription.
  ///
  /// In en, this message translates to:
  /// **'Theme, language, and save-folder behavior.'**
  String get settingsWorkspaceDescription;

  /// No description provided for @settingsStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsStorage;

  /// No description provided for @settingsStorageDescription.
  ///
  /// In en, this message translates to:
  /// **'Recording space, internal usage, and disk health.'**
  String get settingsStorageDescription;

  /// No description provided for @settingsShortcutsDescription.
  ///
  /// In en, this message translates to:
  /// **'Customize keyboard shortcuts and resolve conflicts.'**
  String get settingsShortcutsDescription;

  /// No description provided for @settingsLicense.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get settingsLicense;

  /// No description provided for @settingsLicenseDescription.
  ///
  /// In en, this message translates to:
  /// **'Plan status, entitlement, device link, and upgrade actions.'**
  String get settingsLicenseDescription;

  /// No description provided for @settingsPermissions.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get settingsPermissions;

  /// No description provided for @settingsPermissionsDescription.
  ///
  /// In en, this message translates to:
  /// **'Access status and quick links to System Settings.'**
  String get settingsPermissionsDescription;

  /// No description provided for @settingsDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get settingsDiagnostics;

  /// No description provided for @settingsDiagnosticsDescription.
  ///
  /// In en, this message translates to:
  /// **'Logs and troubleshooting utilities.'**
  String get settingsDiagnosticsDescription;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsAboutDescription.
  ///
  /// In en, this message translates to:
  /// **'Version information, support, and legal links.'**
  String get settingsAboutDescription;

  /// No description provided for @permissionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get permissionsTitle;

  /// No description provided for @permissionsHelpText.
  ///
  /// In en, this message translates to:
  /// **'Review which permissions Clingfy can use and jump directly to the relevant System Settings pane.'**
  String get permissionsHelpText;

  /// No description provided for @permissionsRefreshStatus.
  ///
  /// In en, this message translates to:
  /// **'Refresh Status'**
  String get permissionsRefreshStatus;

  /// No description provided for @permissionsGranted.
  ///
  /// In en, this message translates to:
  /// **'Granted'**
  String get permissionsGranted;

  /// No description provided for @permissionsNotGranted.
  ///
  /// In en, this message translates to:
  /// **'Not granted'**
  String get permissionsNotGranted;

  /// No description provided for @permissionsRequired.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get permissionsRequired;

  /// No description provided for @permissionsOptional.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get permissionsOptional;

  /// No description provided for @permissionsScreenRecording.
  ///
  /// In en, this message translates to:
  /// **'Screen Recording'**
  String get permissionsScreenRecording;

  /// No description provided for @permissionsMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get permissionsMicrophone;

  /// No description provided for @permissionsCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get permissionsCamera;

  /// No description provided for @permissionsAccessibility.
  ///
  /// In en, this message translates to:
  /// **'Accessibility'**
  String get permissionsAccessibility;

  /// No description provided for @permissionsScreenRecordingHelp.
  ///
  /// In en, this message translates to:
  /// **'Required to capture a display, window, or selected screen area.'**
  String get permissionsScreenRecordingHelp;

  /// No description provided for @permissionsMicrophoneHelp.
  ///
  /// In en, this message translates to:
  /// **'Lets Clingfy include your voice narration in recordings.'**
  String get permissionsMicrophoneHelp;

  /// No description provided for @permissionsCameraHelp.
  ///
  /// In en, this message translates to:
  /// **'Lets Clingfy show your face-cam overlay while recording.'**
  String get permissionsCameraHelp;

  /// No description provided for @permissionsAccessibilityHelp.
  ///
  /// In en, this message translates to:
  /// **'Used for click highlights and cursor-aware effects.'**
  String get permissionsAccessibilityHelp;

  /// No description provided for @permissionsChangedHint.
  ///
  /// In en, this message translates to:
  /// **'If you change a permission in System Settings, return to Clingfy and refresh this page to see the latest status.'**
  String get permissionsChangedHint;

  /// No description provided for @permissionsGrantAccess.
  ///
  /// In en, this message translates to:
  /// **'Grant Access'**
  String get permissionsGrantAccess;

  /// No description provided for @settingsLinks.
  ///
  /// In en, this message translates to:
  /// **'Links'**
  String get settingsLinks;

  /// No description provided for @appTheme.
  ///
  /// In en, this message translates to:
  /// **'App Theme'**
  String get appTheme;

  /// No description provided for @appThemeDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose your preferred appearance'**
  String get appThemeDescription;

  /// No description provided for @systemDefault.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get systemDefault;

  /// No description provided for @light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get light;

  /// No description provided for @dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// No description provided for @appLanguage.
  ///
  /// In en, this message translates to:
  /// **'App Language'**
  String get appLanguage;

  /// No description provided for @appLanguageDescription.
  ///
  /// In en, this message translates to:
  /// **'Select the language for the application'**
  String get appLanguageDescription;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @arabic.
  ///
  /// In en, this message translates to:
  /// **'Arabic'**
  String get arabic;

  /// No description provided for @romanian.
  ///
  /// In en, this message translates to:
  /// **'Romanian'**
  String get romanian;

  /// No description provided for @exportVideo.
  ///
  /// In en, this message translates to:
  /// **'Export Video'**
  String get exportVideo;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @enterVideoName.
  ///
  /// In en, this message translates to:
  /// **'Enter a name for your video:'**
  String get enterVideoName;

  /// No description provided for @filename.
  ///
  /// In en, this message translates to:
  /// **'Filename'**
  String get filename;

  /// No description provided for @matchSystem.
  ///
  /// In en, this message translates to:
  /// **'Match system'**
  String get matchSystem;

  /// No description provided for @keyboardShortcuts.
  ///
  /// In en, this message translates to:
  /// **'Keyboard Shortcuts'**
  String get keyboardShortcuts;

  /// No description provided for @toggleRecording.
  ///
  /// In en, this message translates to:
  /// **'Toggle Recording'**
  String get toggleRecording;

  /// No description provided for @refreshDevices.
  ///
  /// In en, this message translates to:
  /// **'Refresh Devices'**
  String get refreshDevices;

  /// No description provided for @toggleActionBar.
  ///
  /// In en, this message translates to:
  /// **'Toggle Action Bar'**
  String get toggleActionBar;

  /// No description provided for @cycleOverlayMode.
  ///
  /// In en, this message translates to:
  /// **'Cycle Overlay Mode'**
  String get cycleOverlayMode;

  /// No description provided for @pressKeyToCapture.
  ///
  /// In en, this message translates to:
  /// **'Press a key combination… Esc to cancel'**
  String get pressKeyToCapture;

  /// No description provided for @shortcutCollision.
  ///
  /// In en, this message translates to:
  /// **'Shortcut already used by {action}'**
  String shortcutCollision(Object action);

  /// No description provided for @resetShortcuts.
  ///
  /// In en, this message translates to:
  /// **'Reset Shortcuts'**
  String get resetShortcuts;

  /// No description provided for @countdown.
  ///
  /// In en, this message translates to:
  /// **'Countdown'**
  String get countdown;

  /// No description provided for @seconds.
  ///
  /// In en, this message translates to:
  /// **'{value} s'**
  String seconds(Object value);

  /// No description provided for @recordingFolderBehavior.
  ///
  /// In en, this message translates to:
  /// **'Recording folder behavior'**
  String get recordingFolderBehavior;

  /// No description provided for @openFolderAfterStop.
  ///
  /// In en, this message translates to:
  /// **'Open folder after stopping recording'**
  String get openFolderAfterStop;

  /// No description provided for @openFolderAfterExport.
  ///
  /// In en, this message translates to:
  /// **'Open folder after exporting video'**
  String get openFolderAfterExport;

  /// No description provided for @confirmations.
  ///
  /// In en, this message translates to:
  /// **'Confirmations'**
  String get confirmations;

  /// No description provided for @warnBeforeClosingUnexportedRecording.
  ///
  /// In en, this message translates to:
  /// **'Warn before closing an unexported recording'**
  String get warnBeforeClosingUnexportedRecording;

  /// No description provided for @warnBeforeClosingUnexportedRecordingDescription.
  ///
  /// In en, this message translates to:
  /// **'Show a confirmation before closing the current recording if it has not been exported yet.'**
  String get warnBeforeClosingUnexportedRecordingDescription;

  /// No description provided for @closeUnexportedRecordingTitle.
  ///
  /// In en, this message translates to:
  /// **'Close this recording?'**
  String get closeUnexportedRecordingTitle;

  /// No description provided for @closeUnexportedRecordingMessage.
  ///
  /// In en, this message translates to:
  /// **'You haven’t exported this recording yet. If you close it now, you’ll lose access to it in the current session.'**
  String get closeUnexportedRecordingMessage;

  /// No description provided for @doNotShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Do not show again'**
  String get doNotShowAgain;

  /// No description provided for @aboutThisApp.
  ///
  /// In en, this message translates to:
  /// **'About this app'**
  String get aboutThisApp;

  /// No description provided for @aboutClingfy.
  ///
  /// In en, this message translates to:
  /// **'About Clingfy'**
  String get aboutClingfy;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version {value}'**
  String version(Object value);

  /// No description provided for @aboutDeveloperModeEnabled.
  ///
  /// In en, this message translates to:
  /// **'Developer mode enabled'**
  String get aboutDeveloperModeEnabled;

  /// No description provided for @aboutDeveloperModeDisabled.
  ///
  /// In en, this message translates to:
  /// **'Developer mode disabled'**
  String get aboutDeveloperModeDisabled;

  /// No description provided for @aboutBuildMetadata.
  ///
  /// In en, this message translates to:
  /// **'BUILD METADATA'**
  String get aboutBuildMetadata;

  /// No description provided for @aboutBuildCommit.
  ///
  /// In en, this message translates to:
  /// **'Commit'**
  String get aboutBuildCommit;

  /// No description provided for @aboutBuildBranch.
  ///
  /// In en, this message translates to:
  /// **'Branch'**
  String get aboutBuildBranch;

  /// No description provided for @aboutBuildId.
  ///
  /// In en, this message translates to:
  /// **'Build ID'**
  String get aboutBuildId;

  /// No description provided for @aboutBuildDate.
  ///
  /// In en, this message translates to:
  /// **'Built'**
  String get aboutBuildDate;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for Updates'**
  String get checkForUpdates;

  /// No description provided for @escToCancel.
  ///
  /// In en, this message translates to:
  /// **'Esc to cancel'**
  String get escToCancel;

  /// No description provided for @menuFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get menuFile;

  /// No description provided for @menuView.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get menuView;

  /// No description provided for @showActionBar.
  ///
  /// In en, this message translates to:
  /// **'Show Action Bar'**
  String get showActionBar;

  /// No description provided for @recordingSetupNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Recording setup needs your attention'**
  String get recordingSetupNeedsAttention;

  /// No description provided for @storageOverviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Recording safety'**
  String get storageOverviewTitle;

  /// No description provided for @storageOverviewDescription.
  ///
  /// In en, this message translates to:
  /// **'Monitor system free space and Clingfy workspace usage to avoid failed recordings.'**
  String get storageOverviewDescription;

  /// No description provided for @storageSystemTitle.
  ///
  /// In en, this message translates to:
  /// **'System storage'**
  String get storageSystemTitle;

  /// No description provided for @storageSystemDescription.
  ///
  /// In en, this message translates to:
  /// **'The drive backing Clingfy\'s active capture destination.'**
  String get storageSystemDescription;

  /// No description provided for @storageClingfyTitle.
  ///
  /// In en, this message translates to:
  /// **'Clingfy storage'**
  String get storageClingfyTitle;

  /// No description provided for @storageClingfyDescription.
  ///
  /// In en, this message translates to:
  /// **'Internal recordings, temporary captures, and logs.'**
  String get storageClingfyDescription;

  /// No description provided for @storageActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get storageActionsTitle;

  /// No description provided for @storagePathsTitle.
  ///
  /// In en, this message translates to:
  /// **'Paths'**
  String get storagePathsTitle;

  /// No description provided for @storageHealthy.
  ///
  /// In en, this message translates to:
  /// **'Healthy'**
  String get storageHealthy;

  /// No description provided for @storageWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get storageWarning;

  /// No description provided for @storageCritical.
  ///
  /// In en, this message translates to:
  /// **'Critical'**
  String get storageCritical;

  /// No description provided for @storageHealthyMessage.
  ///
  /// In en, this message translates to:
  /// **'Your system has enough free space for normal recording.'**
  String get storageHealthyMessage;

  /// No description provided for @storageWarningMessage.
  ///
  /// In en, this message translates to:
  /// **'Free space is getting low. Long recordings may fail.'**
  String get storageWarningMessage;

  /// No description provided for @storageCriticalMessage.
  ///
  /// In en, this message translates to:
  /// **'Recording is blocked until more disk space is available.'**
  String get storageCriticalMessage;

  /// No description provided for @storageRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get storageRefresh;

  /// No description provided for @storageOpenRecordingsFolder.
  ///
  /// In en, this message translates to:
  /// **'Open recordings folder'**
  String get storageOpenRecordingsFolder;

  /// No description provided for @storageOpenTempFolder.
  ///
  /// In en, this message translates to:
  /// **'Open temp folder'**
  String get storageOpenTempFolder;

  /// No description provided for @storageClearCachedRecordings.
  ///
  /// In en, this message translates to:
  /// **'Clear cached recordings'**
  String get storageClearCachedRecordings;

  /// No description provided for @storageClearCachedRecordingsConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear cached recordings?'**
  String get storageClearCachedRecordingsConfirmTitle;

  /// No description provided for @storageClearCachedRecordingsConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'This removes Clingfy\'s internal recording copies and sidecars. Exported recordings are not deleted, and this action cannot be undone.'**
  String get storageClearCachedRecordingsConfirmMessage;

  /// No description provided for @storageClearCachedRecordingsConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Clear recordings'**
  String get storageClearCachedRecordingsConfirmAction;

  /// No description provided for @storageClearCachedRecordingsSuccess.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Removed 1 cached recording.} other{Removed {count} cached recordings.}}'**
  String storageClearCachedRecordingsSuccess(int count);

  /// No description provided for @storageStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get storageStatusLabel;

  /// No description provided for @storageTotalSpace.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get storageTotalSpace;

  /// No description provided for @storageUsedSpace.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get storageUsedSpace;

  /// No description provided for @storageFreeSpace.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get storageFreeSpace;

  /// No description provided for @storageRecordings.
  ///
  /// In en, this message translates to:
  /// **'Recordings'**
  String get storageRecordings;

  /// No description provided for @storageTemp.
  ///
  /// In en, this message translates to:
  /// **'Temp'**
  String get storageTemp;

  /// No description provided for @storageLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get storageLogs;

  /// No description provided for @storageClingfyTotal.
  ///
  /// In en, this message translates to:
  /// **'Total Clingfy usage'**
  String get storageClingfyTotal;

  /// No description provided for @storageRecordingsPath.
  ///
  /// In en, this message translates to:
  /// **'Recordings folder'**
  String get storageRecordingsPath;

  /// No description provided for @storageTempPath.
  ///
  /// In en, this message translates to:
  /// **'Temp folder'**
  String get storageTempPath;

  /// No description provided for @storageLogsPath.
  ///
  /// In en, this message translates to:
  /// **'Logs folder'**
  String get storageLogsPath;

  /// No description provided for @storageActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Storage action failed.'**
  String get storageActionFailed;

  /// No description provided for @storageFreeNow.
  ///
  /// In en, this message translates to:
  /// **'Free now: {value}'**
  String storageFreeNow(String value);

  /// No description provided for @missingRequiredPermission.
  ///
  /// In en, this message translates to:
  /// **'Missing required permission'**
  String get missingRequiredPermission;

  /// No description provided for @missingOptionalPermissionsForRequestedFeatures.
  ///
  /// In en, this message translates to:
  /// **'Missing optional permissions for requested features'**
  String get missingOptionalPermissionsForRequestedFeatures;

  /// No description provided for @grantPermissions.
  ///
  /// In en, this message translates to:
  /// **'Grant permissions'**
  String get grantPermissions;

  /// No description provided for @recordWithoutMissingFeatures.
  ///
  /// In en, this message translates to:
  /// **'Record without missing features'**
  String get recordWithoutMissingFeatures;

  /// No description provided for @storagePreflightTitle.
  ///
  /// In en, this message translates to:
  /// **'Storage needs your attention'**
  String get storagePreflightTitle;

  /// No description provided for @storagePreflightCriticalIntro.
  ///
  /// In en, this message translates to:
  /// **'Clingfy detected critically low free space on the active recording drive. Recording is blocked to avoid failed captures.'**
  String get storagePreflightCriticalIntro;

  /// No description provided for @storagePreflightWarningIntro.
  ///
  /// In en, this message translates to:
  /// **'Free space is getting low. Long recordings may fail before they finish.'**
  String get storagePreflightWarningIntro;

  /// No description provided for @storageAvailableNow.
  ///
  /// In en, this message translates to:
  /// **'Available now'**
  String get storageAvailableNow;

  /// No description provided for @storageRecordingBlockedBelow.
  ///
  /// In en, this message translates to:
  /// **'Recording is blocked below'**
  String get storageRecordingBlockedBelow;

  /// No description provided for @storageRecommendedFreeSpace.
  ///
  /// In en, this message translates to:
  /// **'Recommended free space'**
  String get storageRecommendedFreeSpace;

  /// No description provided for @openStorageSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Storage Settings'**
  String get openStorageSettings;

  /// No description provided for @recordAnyway.
  ///
  /// In en, this message translates to:
  /// **'Record anyway'**
  String get recordAnyway;

  /// No description provided for @storageBypassAndRecord.
  ///
  /// In en, this message translates to:
  /// **'Bypass and record'**
  String get storageBypassAndRecord;

  /// No description provided for @cameraForFaceCam.
  ///
  /// In en, this message translates to:
  /// **'Camera for Face Cam'**
  String get cameraForFaceCam;

  /// No description provided for @microphoneForVoice.
  ///
  /// In en, this message translates to:
  /// **'Microphone for Voice'**
  String get microphoneForVoice;

  /// No description provided for @accessibilityForCursorHighlight.
  ///
  /// In en, this message translates to:
  /// **'Accessibility for Cursor Highlight'**
  String get accessibilityForCursorHighlight;

  /// No description provided for @menuRecord.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get menuRecord;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @appDescription.
  ///
  /// In en, this message translates to:
  /// **'A simple, powerful screen recorder for macOS.'**
  String get appDescription;

  /// No description provided for @visitWebsite.
  ///
  /// In en, this message translates to:
  /// **'Visit Website'**
  String get visitWebsite;

  /// No description provided for @contactSupport.
  ///
  /// In en, this message translates to:
  /// **'Contact Support'**
  String get contactSupport;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// No description provided for @termsOfService.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get termsOfService;

  /// No description provided for @locationLabel.
  ///
  /// In en, this message translates to:
  /// **'Location:'**
  String get locationLabel;

  /// No description provided for @changeButtonLabel.
  ///
  /// In en, this message translates to:
  /// **'Change...'**
  String get changeButtonLabel;

  /// No description provided for @cancelExport.
  ///
  /// In en, this message translates to:
  /// **'Cancel Export'**
  String get cancelExport;

  /// No description provided for @cancelExportConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to stop the export process?'**
  String get cancelExportConfirm;

  /// No description provided for @keepExporting.
  ///
  /// In en, this message translates to:
  /// **'Keep Exporting'**
  String get keepExporting;

  /// No description provided for @stopExport.
  ///
  /// In en, this message translates to:
  /// **'Stop Export'**
  String get stopExport;

  /// No description provided for @runInBackground.
  ///
  /// In en, this message translates to:
  /// **'Run in background'**
  String get runInBackground;

  /// No description provided for @hideProgress.
  ///
  /// In en, this message translates to:
  /// **'Hide progress'**
  String get hideProgress;

  /// No description provided for @showProgress.
  ///
  /// In en, this message translates to:
  /// **'Show progress'**
  String get showProgress;

  /// No description provided for @cancelingExport.
  ///
  /// In en, this message translates to:
  /// **'Canceling export...'**
  String get cancelingExport;

  /// No description provided for @exportAlreadyInProgress.
  ///
  /// In en, this message translates to:
  /// **'An export is already in progress.'**
  String get exportAlreadyInProgress;

  /// No description provided for @errAlreadyRecording.
  ///
  /// In en, this message translates to:
  /// **'A recording is already in progress.'**
  String get errAlreadyRecording;

  /// No description provided for @errNoWindowSelected.
  ///
  /// In en, this message translates to:
  /// **'Please select a window to record.'**
  String get errNoWindowSelected;

  /// No description provided for @errNoAreaSelected.
  ///
  /// In en, this message translates to:
  /// **'Please select an area to record first.'**
  String get errNoAreaSelected;

  /// No description provided for @errTargetError.
  ///
  /// In en, this message translates to:
  /// **'Unable to determine what should be recorded.'**
  String get errTargetError;

  /// No description provided for @errNotRecording.
  ///
  /// In en, this message translates to:
  /// **'No active recording to stop.'**
  String get errNotRecording;

  /// No description provided for @errInvalidRecordingState.
  ///
  /// In en, this message translates to:
  /// **'That action is not available in the current recording state.'**
  String get errInvalidRecordingState;

  /// No description provided for @errPauseResumeUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Pause and resume are not supported for the current recording setup.'**
  String get errPauseResumeUnsupported;

  /// No description provided for @errUnknownAudioDevice.
  ///
  /// In en, this message translates to:
  /// **'Selected audio device is no longer available.'**
  String get errUnknownAudioDevice;

  /// No description provided for @errBadQuality.
  ///
  /// In en, this message translates to:
  /// **'Invalid recording quality.'**
  String get errBadQuality;

  /// No description provided for @errScreenRecordingPermission.
  ///
  /// In en, this message translates to:
  /// **'Enable Screen Recording in System Settings > Privacy & Security > Screen Recording, then try again.'**
  String get errScreenRecordingPermission;

  /// No description provided for @errWindowUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The selected window is no longer available. Refresh the list and pick it again.'**
  String get errWindowUnavailable;

  /// No description provided for @errRecordingError.
  ///
  /// In en, this message translates to:
  /// **'A recording error occurred: {error}'**
  String errRecordingError(Object error);

  /// No description provided for @errOutputUrlError.
  ///
  /// In en, this message translates to:
  /// **'Could not create output file: {error}'**
  String errOutputUrlError(Object error);

  /// No description provided for @errAccessibilityPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Enable Accessibility for cursor highlight in System Settings, then relaunch.'**
  String get errAccessibilityPermissionRequired;

  /// No description provided for @errMicrophonePermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Enable microphone access in System Settings > Privacy & Security > Microphone, then try again.'**
  String get errMicrophonePermissionRequired;

  /// No description provided for @errExportError.
  ///
  /// In en, this message translates to:
  /// **'An error occurred during export: {error}'**
  String errExportError(Object error);

  /// No description provided for @errCameraPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Enable camera in System Settings > Privacy & Security > Camera.'**
  String get errCameraPermissionDenied;

  /// No description provided for @shape.
  ///
  /// In en, this message translates to:
  /// **'Shape'**
  String get shape;

  /// No description provided for @squircle.
  ///
  /// In en, this message translates to:
  /// **'Squircle'**
  String get squircle;

  /// No description provided for @circle.
  ///
  /// In en, this message translates to:
  /// **'Circle'**
  String get circle;

  /// No description provided for @roundedRect.
  ///
  /// In en, this message translates to:
  /// **'Rounded Rect'**
  String get roundedRect;

  /// No description provided for @square.
  ///
  /// In en, this message translates to:
  /// **'Square'**
  String get square;

  /// No description provided for @hexagon.
  ///
  /// In en, this message translates to:
  /// **'Hexagon'**
  String get hexagon;

  /// No description provided for @star.
  ///
  /// In en, this message translates to:
  /// **'Star'**
  String get star;

  /// No description provided for @cornerRoundness.
  ///
  /// In en, this message translates to:
  /// **'Corner Roundness: {value}%'**
  String cornerRoundness(Object value);

  /// No description provided for @sizePx.
  ///
  /// In en, this message translates to:
  /// **'Size: {value}px'**
  String sizePx(Object value);

  /// No description provided for @opacityPercent.
  ///
  /// In en, this message translates to:
  /// **'Opacity: {value}%'**
  String opacityPercent(Object value);

  /// No description provided for @mirrorSelfView.
  ///
  /// In en, this message translates to:
  /// **'Mirror self-view'**
  String get mirrorSelfView;

  /// No description provided for @chromaKey.
  ///
  /// In en, this message translates to:
  /// **'Chroma key (green screen)'**
  String get chromaKey;

  /// No description provided for @keyTolerance.
  ///
  /// In en, this message translates to:
  /// **'Key Tolerance: {value}%'**
  String keyTolerance(Object value);

  /// No description provided for @chromaKeyColor.
  ///
  /// In en, this message translates to:
  /// **'Chroma key color'**
  String get chromaKeyColor;

  /// No description provided for @pickChromaKeyColor.
  ///
  /// In en, this message translates to:
  /// **'Pick chroma key color'**
  String get pickChromaKeyColor;

  /// No description provided for @targetColorToRemove.
  ///
  /// In en, this message translates to:
  /// **'Target color to remove'**
  String get targetColorToRemove;

  /// No description provided for @position.
  ///
  /// In en, this message translates to:
  /// **'Position'**
  String get position;

  /// No description provided for @customPosition.
  ///
  /// In en, this message translates to:
  /// **'Custom position'**
  String get customPosition;

  /// No description provided for @customPositionHint.
  ///
  /// In en, this message translates to:
  /// **'Dragged manually. Select a corner to snap back.'**
  String get customPositionHint;

  /// No description provided for @shadow.
  ///
  /// In en, this message translates to:
  /// **'Shadow'**
  String get shadow;

  /// No description provided for @border.
  ///
  /// In en, this message translates to:
  /// **'Border'**
  String get border;

  /// No description provided for @pickBorderColor.
  ///
  /// In en, this message translates to:
  /// **'Pick border color'**
  String get pickBorderColor;

  /// No description provided for @borderWidth.
  ///
  /// In en, this message translates to:
  /// **'Border width: {value} px'**
  String borderWidth(Object value);

  /// No description provided for @diagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnosticsTitle;

  /// No description provided for @diagnosticsHelpText.
  ///
  /// In en, this message translates to:
  /// **'If something goes wrong, open the logs folder and send today\'s log file to support.'**
  String get diagnosticsHelpText;

  /// No description provided for @openLogsFolder.
  ///
  /// In en, this message translates to:
  /// **'Open Logs Folder'**
  String get openLogsFolder;

  /// No description provided for @revealTodayLog.
  ///
  /// In en, this message translates to:
  /// **'Reveal Today\'s Log File'**
  String get revealTodayLog;

  /// No description provided for @copyLogPath.
  ///
  /// In en, this message translates to:
  /// **'Copy Path'**
  String get copyLogPath;

  /// No description provided for @errVideoFileMissing.
  ///
  /// In en, this message translates to:
  /// **'Recording file was moved or deleted.'**
  String get errVideoFileMissing;

  /// No description provided for @errCursorFileMissing.
  ///
  /// In en, this message translates to:
  /// **'Cursor data is missing. Cursor effects are disabled.'**
  String get errCursorFileMissing;

  /// No description provided for @errExportInputMissing.
  ///
  /// In en, this message translates to:
  /// **'Recording file not found. It may have been moved or deleted.'**
  String get errExportInputMissing;

  /// No description provided for @errAssetInvalid.
  ///
  /// In en, this message translates to:
  /// **'Failed to prepare video preview.'**
  String get errAssetInvalid;

  /// No description provided for @applyEffects.
  ///
  /// In en, this message translates to:
  /// **'Apply Effects'**
  String get applyEffects;

  /// No description provided for @recordingSaved.
  ///
  /// In en, this message translates to:
  /// **'Recording saved:'**
  String get recordingSaved;

  /// No description provided for @exportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Export successful:'**
  String get exportSuccess;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @cursorDataMissing.
  ///
  /// In en, this message translates to:
  /// **'Cursor data missing'**
  String get cursorDataMissing;

  /// No description provided for @voiceBoost.
  ///
  /// In en, this message translates to:
  /// **'Voice Boost'**
  String get voiceBoost;

  /// No description provided for @audioGain.
  ///
  /// In en, this message translates to:
  /// **'Audio Gain'**
  String get audioGain;

  /// No description provided for @volume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get volume;

  /// No description provided for @micInputLevel.
  ///
  /// In en, this message translates to:
  /// **'Mic input level'**
  String get micInputLevel;

  /// No description provided for @micInputMonitorTitle.
  ///
  /// In en, this message translates to:
  /// **'Input monitoring'**
  String get micInputMonitorTitle;

  /// No description provided for @micInputMonitorInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get micInputMonitorInactive;

  /// No description provided for @micInputMonitorDisabledHint.
  ///
  /// In en, this message translates to:
  /// **'Select a microphone to preview input level.'**
  String get micInputMonitorDisabledHint;

  /// No description provided for @micInputMonitorLiveHint.
  ///
  /// In en, this message translates to:
  /// **'Monitoring live input.'**
  String get micInputMonitorLiveHint;

  /// No description provided for @micInputMonitorLowBadge.
  ///
  /// In en, this message translates to:
  /// **'Low input'**
  String get micInputMonitorLowBadge;

  /// No description provided for @micInputMonitorLowHint.
  ///
  /// In en, this message translates to:
  /// **'Raise input gain or move closer.'**
  String get micInputMonitorLowHint;

  /// No description provided for @micInputMonitorExpandTooltip.
  ///
  /// In en, this message translates to:
  /// **'Show detailed input monitor'**
  String get micInputMonitorExpandTooltip;

  /// No description provided for @micInputMonitorCollapseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Hide detailed input monitor'**
  String get micInputMonitorCollapseTooltip;

  /// No description provided for @micInputTooLowWarning.
  ///
  /// In en, this message translates to:
  /// **'Mic input is very low. Raise input level or move closer to the mic.'**
  String get micInputTooLowWarning;

  /// No description provided for @noMicAudioFound.
  ///
  /// In en, this message translates to:
  /// **'No mic audio track found'**
  String get noMicAudioFound;

  /// No description provided for @autoNormalizeOnExport.
  ///
  /// In en, this message translates to:
  /// **'Auto-normalize on export'**
  String get autoNormalizeOnExport;

  /// No description provided for @targetLoudness.
  ///
  /// In en, this message translates to:
  /// **'Target loudness'**
  String get targetLoudness;

  /// No description provided for @selectCameraHint.
  ///
  /// In en, this message translates to:
  /// **'Select a camera to configure overlay settings'**
  String get selectCameraHint;

  /// No description provided for @closePreview.
  ///
  /// In en, this message translates to:
  /// **'Close Preview'**
  String get closePreview;

  /// No description provided for @preparingPreview.
  ///
  /// In en, this message translates to:
  /// **'Preparing preview...'**
  String get preparingPreview;

  /// No description provided for @menuStartRecording.
  ///
  /// In en, this message translates to:
  /// **'Start Recording'**
  String get menuStartRecording;

  /// No description provided for @menuStopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop Recording'**
  String get menuStopRecording;

  /// No description provided for @menuOpenApp.
  ///
  /// In en, this message translates to:
  /// **'Open Clingfy'**
  String get menuOpenApp;

  /// No description provided for @menuQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit Clingfy'**
  String get menuQuit;

  /// No description provided for @captureSettings.
  ///
  /// In en, this message translates to:
  /// **'Capture Settings'**
  String get captureSettings;

  /// No description provided for @captureSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Configure how screen capture behaves.'**
  String get captureSettingsDescription;

  /// No description provided for @excludeRecorderAppFromCapture.
  ///
  /// In en, this message translates to:
  /// **'Exclude recorder app from capture'**
  String get excludeRecorderAppFromCapture;

  /// No description provided for @excludeRecorderAppFromCaptureDescription.
  ///
  /// In en, this message translates to:
  /// **'When enabled, the recorder window is hidden from recordings. Disable to include it (useful for tutorials about this app).'**
  String get excludeRecorderAppFromCaptureDescription;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @loadingYourSettings.
  ///
  /// In en, this message translates to:
  /// **'Loading your settings...'**
  String get loadingYourSettings;

  /// No description provided for @renderingErrorFallbackMessage.
  ///
  /// In en, this message translates to:
  /// **'A rendering error occurred.\nCheck logs for details.'**
  String get renderingErrorFallbackMessage;

  /// No description provided for @debugResetPreferencesTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset preferences?'**
  String get debugResetPreferencesTitle;

  /// No description provided for @debugResetPreferencesMessage.
  ///
  /// In en, this message translates to:
  /// **'This clears all saved settings.'**
  String get debugResetPreferencesMessage;

  /// No description provided for @debugResetPreferencesConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get debugResetPreferencesConfirm;

  /// No description provided for @debugResetPreferencesSemanticLabel.
  ///
  /// In en, this message translates to:
  /// **'Reset preferences (Debug)'**
  String get debugResetPreferencesSemanticLabel;

  /// No description provided for @diagnosticsLogFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Log file not found. Try reproducing the issue first.'**
  String get diagnosticsLogFileNotFound;

  /// No description provided for @diagnosticsLogFileUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Log file path is unavailable right now.'**
  String get diagnosticsLogFileUnavailable;

  /// No description provided for @diagnosticsActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete that action.'**
  String get diagnosticsActionFailed;

  /// No description provided for @diagnosticsLogRevealed.
  ///
  /// In en, this message translates to:
  /// **'Revealed today\'s log file.'**
  String get diagnosticsLogRevealed;

  /// No description provided for @recordingSystemAudio.
  ///
  /// In en, this message translates to:
  /// **'System audio'**
  String get recordingSystemAudio;

  /// No description provided for @recordingExcludeMicFromSystemAudio.
  ///
  /// In en, this message translates to:
  /// **'Exclude my mic from system audio'**
  String get recordingExcludeMicFromSystemAudio;

  /// No description provided for @restartApp.
  ///
  /// In en, this message translates to:
  /// **'Restart App'**
  String get restartApp;

  /// No description provided for @permissionsOnboardingWelcomeRail.
  ///
  /// In en, this message translates to:
  /// **'Welcome'**
  String get permissionsOnboardingWelcomeRail;

  /// No description provided for @permissionsOnboardingMicCameraRail.
  ///
  /// In en, this message translates to:
  /// **'Mic + Camera'**
  String get permissionsOnboardingMicCameraRail;

  /// No description provided for @permissionsOnboardingStepLabel.
  ///
  /// In en, this message translates to:
  /// **'Step {current} of 4'**
  String permissionsOnboardingStepLabel(int current);

  /// No description provided for @permissionsOnboardingWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Clingfy'**
  String get permissionsOnboardingWelcomeTitle;

  /// No description provided for @permissionsOnboardingWelcomeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A quick studio setup and you’re ready to record in minutes.'**
  String get permissionsOnboardingWelcomeSubtitle;

  /// No description provided for @permissionsOnboardingTrustLocalFirst.
  ///
  /// In en, this message translates to:
  /// **'Local-first: your recordings stay on your Mac.'**
  String get permissionsOnboardingTrustLocalFirst;

  /// No description provided for @permissionsOnboardingTrustPermissionControl.
  ///
  /// In en, this message translates to:
  /// **'You control permissions anytime in System Settings.'**
  String get permissionsOnboardingTrustPermissionControl;

  /// No description provided for @permissionsOnboardingFeatureExportsTitle.
  ///
  /// In en, this message translates to:
  /// **'Crisp 4K+ exports'**
  String get permissionsOnboardingFeatureExportsTitle;

  /// No description provided for @permissionsOnboardingFeatureExportsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Presets for YouTube, reels, and more.'**
  String get permissionsOnboardingFeatureExportsSubtitle;

  /// No description provided for @permissionsOnboardingFeatureZoomTitle.
  ///
  /// In en, this message translates to:
  /// **'Zoom-follow + cursor effects'**
  String get permissionsOnboardingFeatureZoomTitle;

  /// No description provided for @permissionsOnboardingFeatureZoomSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Help viewers track what matters.'**
  String get permissionsOnboardingFeatureZoomSubtitle;

  /// No description provided for @permissionsOnboardingScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Screen Recording (Required)'**
  String get permissionsOnboardingScreenTitle;

  /// No description provided for @permissionsOnboardingScreenSubtitle.
  ///
  /// In en, this message translates to:
  /// **'macOS requires this before any recording can start. Takes about 15 seconds.'**
  String get permissionsOnboardingScreenSubtitle;

  /// No description provided for @permissionsOnboardingWhyAreYouAsking.
  ///
  /// In en, this message translates to:
  /// **'Why are you asking?'**
  String get permissionsOnboardingWhyAreYouAsking;

  /// No description provided for @permissionsOnboardingWhyIsThisNeeded.
  ///
  /// In en, this message translates to:
  /// **'Why is this needed?'**
  String get permissionsOnboardingWhyIsThisNeeded;

  /// No description provided for @permissionsOnboardingWhyScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Why Screen Recording?'**
  String get permissionsOnboardingWhyScreenTitle;

  /// No description provided for @permissionsOnboardingWhyScreenSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This permission is required by macOS to capture pixels from your screen.'**
  String get permissionsOnboardingWhyScreenSubtitle;

  /// No description provided for @permissionsOnboardingWhyScreenBullet1.
  ///
  /// In en, this message translates to:
  /// **'Needed for full display, window capture, and custom area recording.'**
  String get permissionsOnboardingWhyScreenBullet1;

  /// No description provided for @permissionsOnboardingWhyScreenBullet2.
  ///
  /// In en, this message translates to:
  /// **'Clingfy records locally; exporting is something you initiate.'**
  String get permissionsOnboardingWhyScreenBullet2;

  /// No description provided for @permissionsOnboardingWhyScreenBullet3.
  ///
  /// In en, this message translates to:
  /// **'You can disable it anytime in System Settings.'**
  String get permissionsOnboardingWhyScreenBullet3;

  /// No description provided for @permissionsOnboardingWhyScreenFooter.
  ///
  /// In en, this message translates to:
  /// **'If macOS shows a toggle for Clingfy, make sure it is on.'**
  String get permissionsOnboardingWhyScreenFooter;

  /// No description provided for @permissionsOnboardingScreenTrustLine1.
  ///
  /// In en, this message translates to:
  /// **'Local-first: recordings stay on your Mac.'**
  String get permissionsOnboardingScreenTrustLine1;

  /// No description provided for @permissionsOnboardingScreenTrustLine2.
  ///
  /// In en, this message translates to:
  /// **'You’re always in control — change this anytime.'**
  String get permissionsOnboardingScreenTrustLine2;

  /// No description provided for @permissionsOnboardingRestartHint.
  ///
  /// In en, this message translates to:
  /// **'If macOS shows a toggle, make sure it\'s on. You might need to restart Clingfy.'**
  String get permissionsOnboardingRestartHint;

  /// No description provided for @permissionsOnboardingVoiceCameraTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice & Face-cam (Optional)'**
  String get permissionsOnboardingVoiceCameraTitle;

  /// No description provided for @permissionsOnboardingVoiceCameraSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Recommended for tutorials, but you can skip this and enable it later.'**
  String get permissionsOnboardingVoiceCameraSubtitle;

  /// No description provided for @permissionsOnboardingMicrophoneDescription.
  ///
  /// In en, this message translates to:
  /// **'For narration and voice boost.'**
  String get permissionsOnboardingMicrophoneDescription;

  /// No description provided for @permissionsOnboardingEnableMic.
  ///
  /// In en, this message translates to:
  /// **'Enable Mic'**
  String get permissionsOnboardingEnableMic;

  /// No description provided for @permissionsOnboardingWhyMicrophoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Why Microphone?'**
  String get permissionsOnboardingWhyMicrophoneTitle;

  /// No description provided for @permissionsOnboardingWhyMicrophoneSubtitle.
  ///
  /// In en, this message translates to:
  /// **'So your recordings can include your voice narration.'**
  String get permissionsOnboardingWhyMicrophoneSubtitle;

  /// No description provided for @permissionsOnboardingWhyMicrophoneBullet1.
  ///
  /// In en, this message translates to:
  /// **'Used only when you enable mic recording.'**
  String get permissionsOnboardingWhyMicrophoneBullet1;

  /// No description provided for @permissionsOnboardingWhyMicrophoneBullet2.
  ///
  /// In en, this message translates to:
  /// **'You can pick input devices inside the app.'**
  String get permissionsOnboardingWhyMicrophoneBullet2;

  /// No description provided for @permissionsOnboardingWhyMicrophoneBullet3.
  ///
  /// In en, this message translates to:
  /// **'You can revoke this anytime.'**
  String get permissionsOnboardingWhyMicrophoneBullet3;

  /// No description provided for @permissionsOnboardingCameraDescription.
  ///
  /// In en, this message translates to:
  /// **'Show your face in a customizable bubble.'**
  String get permissionsOnboardingCameraDescription;

  /// No description provided for @permissionsOnboardingEnableCamera.
  ///
  /// In en, this message translates to:
  /// **'Enable Camera'**
  String get permissionsOnboardingEnableCamera;

  /// No description provided for @permissionsOnboardingWhyCameraTitle.
  ///
  /// In en, this message translates to:
  /// **'Why Camera?'**
  String get permissionsOnboardingWhyCameraTitle;

  /// No description provided for @permissionsOnboardingWhyCameraSubtitle.
  ///
  /// In en, this message translates to:
  /// **'For face-cam overlays (optional).'**
  String get permissionsOnboardingWhyCameraSubtitle;

  /// No description provided for @permissionsOnboardingWhyCameraBullet1.
  ///
  /// In en, this message translates to:
  /// **'Only used when you enable the camera bubble.'**
  String get permissionsOnboardingWhyCameraBullet1;

  /// No description provided for @permissionsOnboardingWhyCameraBullet2.
  ///
  /// In en, this message translates to:
  /// **'You can turn it off anytime during recording.'**
  String get permissionsOnboardingWhyCameraBullet2;

  /// No description provided for @permissionsOnboardingWhyCameraBullet3.
  ///
  /// In en, this message translates to:
  /// **'You can revoke this anytime.'**
  String get permissionsOnboardingWhyCameraBullet3;

  /// No description provided for @permissionsOnboardingAudioTrustLine1.
  ///
  /// In en, this message translates to:
  /// **'Optional step — you can record without mic or camera.'**
  String get permissionsOnboardingAudioTrustLine1;

  /// No description provided for @permissionsOnboardingAudioTrustLine2.
  ///
  /// In en, this message translates to:
  /// **'Enable them later anytime from app settings.'**
  String get permissionsOnboardingAudioTrustLine2;

  /// No description provided for @permissionsOnboardingCursorTitle.
  ///
  /// In en, this message translates to:
  /// **'Cursor Magic (Optional)'**
  String get permissionsOnboardingCursorTitle;

  /// No description provided for @permissionsOnboardingCursorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enable click highlights and smoother cursor motion for viewers.'**
  String get permissionsOnboardingCursorSubtitle;

  /// No description provided for @permissionsOnboardingAccessibilityDescription.
  ///
  /// In en, this message translates to:
  /// **'Used to detect mouse clicks for cursor effects.'**
  String get permissionsOnboardingAccessibilityDescription;

  /// No description provided for @permissionsOnboardingCheck.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get permissionsOnboardingCheck;

  /// No description provided for @permissionsOnboardingWhyAccessibilityTitle.
  ///
  /// In en, this message translates to:
  /// **'Why Accessibility?'**
  String get permissionsOnboardingWhyAccessibilityTitle;

  /// No description provided for @permissionsOnboardingWhyAccessibilitySubtitle.
  ///
  /// In en, this message translates to:
  /// **'macOS groups mouse-event access under Accessibility permissions.'**
  String get permissionsOnboardingWhyAccessibilitySubtitle;

  /// No description provided for @permissionsOnboardingWhyAccessibilityBullet1.
  ///
  /// In en, this message translates to:
  /// **'Used for click highlights and Cursor Magic effects.'**
  String get permissionsOnboardingWhyAccessibilityBullet1;

  /// No description provided for @permissionsOnboardingWhyAccessibilityBullet2.
  ///
  /// In en, this message translates to:
  /// **'Recommended for tutorials and demos, but not required to record.'**
  String get permissionsOnboardingWhyAccessibilityBullet2;

  /// No description provided for @permissionsOnboardingWhyAccessibilityBullet3.
  ///
  /// In en, this message translates to:
  /// **'You can revoke it anytime in System Settings.'**
  String get permissionsOnboardingWhyAccessibilityBullet3;

  /// No description provided for @permissionsOnboardingCursorTrustLine1.
  ///
  /// In en, this message translates to:
  /// **'Optional step — your recordings work without it.'**
  String get permissionsOnboardingCursorTrustLine1;

  /// No description provided for @permissionsOnboardingCursorTrustLine2.
  ///
  /// In en, this message translates to:
  /// **'You can enable Cursor Magic later whenever you want.'**
  String get permissionsOnboardingCursorTrustLine2;

  /// No description provided for @permissionsOnboardingSkipForNow.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get permissionsOnboardingSkipForNow;

  /// No description provided for @permissionsOnboardingBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get permissionsOnboardingBack;

  /// No description provided for @permissionsOnboardingNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get permissionsOnboardingNext;

  /// No description provided for @permissionsOnboardingLetsRecord.
  ///
  /// In en, this message translates to:
  /// **'Let’s Record! 🚀'**
  String get permissionsOnboardingLetsRecord;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en', 'ro'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
    case 'ro':
      return AppLocalizationsRo();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
