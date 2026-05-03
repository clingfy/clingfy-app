// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Clingfy — Screen Recorder';

  @override
  String get record => 'Record';

  @override
  String get output => 'Output';

  @override
  String get settings => 'Settings';

  @override
  String get tabScreenAudio => 'Screen & Audio';

  @override
  String get tabFaceCam => 'Face Cam';

  @override
  String get screenTarget => 'Screen target';

  @override
  String get recordTarget => 'Record target';

  @override
  String get captureSource => 'Capture Source';

  @override
  String get chosenScreen => 'Chosen screen';

  @override
  String get appWindowScreen => 'App window’s screen';

  @override
  String get specificAppWindow => 'Specific app window';

  @override
  String get screenUnderMouse => 'Screen under mouse (at start)';

  @override
  String get followMouse => 'Follow mouse (splits files)';

  @override
  String get followMouseNote =>
      'Note: with the current encoder, the recording will split when the mouse moves to another display.';

  @override
  String get display => 'Display';

  @override
  String get refreshDisplays => 'Refresh displays (⌘R)';

  @override
  String get screenToRecord => 'Screen to record';

  @override
  String get mainDisplay => 'Main display';

  @override
  String get appWindow => 'App window';

  @override
  String get refreshWindows => 'Refresh windows';

  @override
  String get windowToRecord => 'Window to record';

  @override
  String get selectAppWindow => 'Select an app window';

  @override
  String get refreshWindowHint =>
      'Refresh if you don’t see your window, then select it above.';

  @override
  String get areaRecording => 'Area recording';

  @override
  String get pickArea => 'Pick area...';

  @override
  String get changeArea => 'Change area';

  @override
  String get revealArea => 'Reveal';

  @override
  String get clearArea => 'Delete image';

  @override
  String get areaRecordingHelper =>
      'Record a custom rectangular area of the screen.';

  @override
  String get noAreaSelected => 'No area selected';

  @override
  String selectedAreaAt(
    Object height,
    Object id,
    Object width,
    Object x,
    Object y,
  ) {
    return 'Display $id: ${width}x$height at ($x, $y)';
  }

  @override
  String get audio => 'Audio';

  @override
  String get pointer => 'Pointer';

  @override
  String get refreshAudio => 'Refresh audio devices (⌘R)';

  @override
  String get inputDevice => 'Input device';

  @override
  String get noAudio => 'No audio';

  @override
  String get camera => 'Camera';

  @override
  String get refreshCameras => 'Refresh cameras (⌘R)';

  @override
  String get cameraDevice => 'Camera device';

  @override
  String get recordingQuality => 'Recording quality';

  @override
  String get quality => 'Quality';

  @override
  String get resolution => 'Resolution';

  @override
  String get frameRate => 'Frame Rate';

  @override
  String fps(Object value) {
    return '$value FPS';
  }

  @override
  String get saveLocation => 'Save location';

  @override
  String get format => 'Format';

  @override
  String get codec => 'Codec';

  @override
  String get bitrate => 'Bitrate';

  @override
  String get hevc => 'HEVC (H.265)';

  @override
  String get h264 => 'H.264';

  @override
  String get auto => 'Auto';

  @override
  String get low => 'Low';

  @override
  String get medium => 'Medium';

  @override
  String get high => 'High';

  @override
  String get original => 'Original';

  @override
  String get fhd1080 => '1080p';

  @override
  String get uhd2k => '2K (1440P)';

  @override
  String get uhd4k => '4K (2160P)';

  @override
  String get uhd8k => '8K (4320P)';

  @override
  String get revealInFinder => 'Reveal in Finder';

  @override
  String get resetToDefault => 'Reset to default';

  @override
  String get openFolder => 'Open Folder';

  @override
  String get recordingHighlight => 'Glow when recording';

  @override
  String get recordingGlowStrength => 'Glow strength';

  @override
  String recordingGlowStrengthPercent(Object value) {
    return 'Glow strength: $value%';
  }

  @override
  String get chooseSaveFolder => 'Choose save folder…';

  @override
  String get defaultSaveFolder => 'Default: ~/Movies/Clingfy';

  @override
  String get duration => 'Duration';

  @override
  String get startAndStop => 'Start & Stop';

  @override
  String get autoStopAfter => 'Auto-stop after';

  @override
  String get preset => 'Preset';

  @override
  String get customMinutes => 'Custom (minutes)';

  @override
  String get forceLetterbox => 'Force 16:9 (letterbox)';

  @override
  String get forceLetterboxSubtitle =>
      'Centers your screen in a 16:9 canvas (e.g., 1080p) with black padding.';

  @override
  String get forceLetterboxHint =>
      'Fixes pillarboxing on YouTube when your screen is ultra-wide or not 16:9.';

  @override
  String get appSettings => 'App Settings';

  @override
  String get appSettingsDescription =>
      'Manage workspace preferences, shortcuts, license status, diagnostics, and app details.';

  @override
  String get openAppSettings => 'Open App Settings';

  @override
  String get expandNavigationRail => 'Expand navigation rail';

  @override
  String get compactNavigationRail => 'Compact navigation rail';

  @override
  String get overlayFaceCam => 'Overlay (Face-cam)';

  @override
  String get overlayFaceCamVisibility => 'Face-cam visibility';

  @override
  String get visibilityAndPlacement => 'Visibility & Placement';

  @override
  String get appearance => 'Appearance';

  @override
  String get style => 'Style';

  @override
  String get effects => 'Effects';

  @override
  String get visibility => 'Visibility';

  @override
  String get overlayHint => 'Overlay will appear when recording starts.';

  @override
  String get recordingIndicator => 'Recording indicator';

  @override
  String get showIndicator => 'Show recording indicator';

  @override
  String get pinToTopRight => 'Pin to top-right';

  @override
  String get indicatorHint =>
      'A small “REC” dot appears while recording. When pinned, it stays in the top-right; otherwise you can drag it.';

  @override
  String get cursorHighlight => 'Cursor highlight';

  @override
  String get cursorHighlightVisibility => 'Cursor highlight visibility';

  @override
  String get cursorHint => 'Cursor highlight is active only when recording.';

  @override
  String get appTitleFull => 'Clingfy — Screen Recorder';

  @override
  String get recordingPathCopied => 'Recording path copied';

  @override
  String get grantAccessibilityPermission =>
      'Grant Accessibility permission to highlight the cursor.';

  @override
  String get openSettings => 'Open Settings';

  @override
  String get export => 'Export';

  @override
  String get exporting => 'Exporting...';

  @override
  String get paywallTitle => 'Unlock Pro exports';

  @override
  String get paywallSubtitle =>
      'Upgrade your plan or activate a license key to continue exporting.';

  @override
  String paywallTrialRemaining(int count) {
    return 'Trial exports remaining: $count';
  }

  @override
  String get paywallTrialTier => 'Trial plan: limited exports to test features';

  @override
  String get paywallLifetimeTier =>
      'Lifetime plan: one-time purchase with update coverage';

  @override
  String get paywallSubscriptionTier =>
      'Subscription plan: ongoing access and updates';

  @override
  String get paywallAlreadyHaveKey => 'Already have a key?';

  @override
  String get paywallLicenseKeyHint => 'Enter license key';

  @override
  String get paywallLicenseKeyRequired => 'Please enter a license key.';

  @override
  String get paywallActivateKey => 'Activate key';

  @override
  String get paywallActivationFailed => 'License activation failed.';

  @override
  String get paywallExportBlocked =>
      'Export is locked. Upgrade or activate a key to continue.';

  @override
  String get paywallConsumeFailed =>
      'Export succeeded, but trial credit sync failed. Check your connection.';

  @override
  String get paywallSubtitleStarter =>
      'Get unlimited exports, no watermark, and full Pro features.';

  @override
  String paywallSubtitleTrial(int count) {
    return 'You have $count free exports remaining. Upgrade to remove limits.';
  }

  @override
  String get paywallCardMonthlyTitle => 'Pro Monthly';

  @override
  String get paywallCardMonthlyPrice => '\$9.99';

  @override
  String get paywallCardMonthlyPeriod => '/ month';

  @override
  String get paywallCardMonthlyDescription => 'Always get the latest features.';

  @override
  String get paywallCardMonthlyFeature1 => 'Unlimited exports';

  @override
  String get paywallCardMonthlyFeature2 => 'No watermark';

  @override
  String get paywallCardMonthlyFeature3 => 'Priority support';

  @override
  String get paywallCardMonthlyCta => 'Subscribe';

  @override
  String get paywallCardLifetimeTitle => 'Lifetime Pro';

  @override
  String get paywallCardLifetimePrice => '\$59.99';

  @override
  String get paywallCardLifetimePeriod => 'one-time';

  @override
  String get paywallCardLifetimeDescription =>
      'Own Clingfy forever + 1 year of updates.';

  @override
  String get paywallCardLifetimeFeature1 => 'Permanent ownership';

  @override
  String get paywallCardLifetimeFeature2 => '1-year updates included';

  @override
  String get paywallCardLifetimeFeature3 => 'Unlimited exports';

  @override
  String get paywallCardLifetimeFeature4 => 'No watermark';

  @override
  String get paywallCardLifetimeCta => 'Buy Lifetime';

  @override
  String get paywallCardExtensionTitle => 'Updates Extension';

  @override
  String get paywallCardExtensionPrice => '\$19.99';

  @override
  String get paywallCardExtensionPeriod => 'one-time';

  @override
  String get paywallCardExtensionDescription =>
      'Extend updates eligibility by +12 months.';

  @override
  String get paywallCardExtensionFeature1 => 'Adds +12 months updates';

  @override
  String get paywallCardExtensionFeature2 => 'Keep lifetime ownership';

  @override
  String get paywallCardExtensionFeature3 => 'Works with existing key';

  @override
  String get paywallCardExtensionCta => 'Extend Updates';

  @override
  String get paywallRecommendedBadge => 'RECOMMENDED';

  @override
  String get paywallActivationSuccess => 'Pro unlocked successfully!';

  @override
  String get paywallPricingOpenFailed => 'Could not open pricing page.';

  @override
  String get licenseDevicesTitle => 'License & Devices';

  @override
  String get licenseDevicesSubtitle =>
      'Manage this Mac\'s license link for device transfer.';

  @override
  String get licensePlanLabel => 'Plan';

  @override
  String get licenseDeviceLinked => 'This device is linked to your license.';

  @override
  String get licenseDeviceNotLinked =>
      'No active license is linked on this device.';

  @override
  String get licenseDeactivateButton => 'Deactivate this device';

  @override
  String get licenseDeactivateConfirmTitle => 'Deactivate this device?';

  @override
  String get licenseDeactivateConfirmBody =>
      'This will unlink the current Mac from your license key on the server.';

  @override
  String get licenseDeactivateConfirmAction => 'Deactivate';

  @override
  String get licenseDeactivateSuccess => 'Device deactivated successfully.';

  @override
  String get licenseDeactivateFailed =>
      'Could not deactivate this device right now.';

  @override
  String get licenseDeactivateUnavailable =>
      'License could not be found on the server.';

  @override
  String get licenseStatusTitle => 'Plan & Entitlement';

  @override
  String get licenseStatusEntitled => 'Pro features unlocked';

  @override
  String get licenseStatusNotEntitled => 'Pro features locked';

  @override
  String get licenseUpdatesCovered => 'Updates covered';

  @override
  String get licenseUpdatesExpired => 'Updates not covered';

  @override
  String get licenseActivateOrUpgrade => 'Activate key or upgrade';

  @override
  String get licenseUpgradeToPro => 'Upgrade to Pro';

  @override
  String get licenseActivateKeyOnly => 'Activate license key';

  @override
  String get licenseExtendUpdates => 'Extend updates';

  @override
  String get licenseSubscriptionActive => 'Subscription active';

  @override
  String get licenseLifetimeActive => 'Lifetime license active';

  @override
  String get licenseActivateKeySecondary => 'Have a key? Activate it';

  @override
  String get licenseSummaryHeroTitle => 'License summary';

  @override
  String get licenseSummaryHeroSubtitle =>
      'Your current plan, entitlement, and update coverage.';

  @override
  String get licenseDetailsTitle => 'License details';

  @override
  String get licenseDetailsSubtitle =>
      'Identity and activation information for this device.';

  @override
  String get licenseActionTitle => 'Next action';

  @override
  String get licenseActionSubtitle =>
      'Recommended next step based on your current plan.';

  @override
  String get licenseKeyLabel => 'License key';

  @override
  String get licenseMemberSince => 'Member since';

  @override
  String get licenseActivatedOnThisDevice => 'Activated on this device';

  @override
  String get licenseUpdatesUntil => 'Updates covered until';

  @override
  String get licenseLinkStatus => 'Device link';

  @override
  String get licenseSummaryStarter =>
      'Activate a key or upgrade to unlock unlimited Pro exports.';

  @override
  String licenseSummaryTrial(int count) {
    return 'You are using Trial with $count exports remaining.';
  }

  @override
  String get licenseSummarySubscriptionActive =>
      'Your subscription is active and all current Pro features are unlocked.';

  @override
  String get licenseSummaryLifetimeCovered =>
      'You own Clingfy Pro permanently and your update coverage is active.';

  @override
  String licenseSummaryLifetimeExpiringSoon(int days) {
    return 'Your lifetime license is active, but update coverage ends in $days days.';
  }

  @override
  String get licenseSummaryLifetimeExpired =>
      'Your lifetime license is active, but update coverage has expired.';

  @override
  String get licensePlanTrial => 'Trial';

  @override
  String get licensePlanLifetime => 'Lifetime';

  @override
  String get licensePlanSubscription => 'Subscription';

  @override
  String get licensePlanStarter => 'Starter';

  @override
  String get layoutSettings => 'Layout Settings';

  @override
  String get effectsSettings => 'Effects Settings';

  @override
  String get exportSettings => 'Export Settings';

  @override
  String get canvas => 'Canvas';

  @override
  String get canvasSettings => 'Canvas Settings';

  @override
  String get cameraSettings => 'Camera Settings';

  @override
  String get postProcessing => 'Post-processing';

  @override
  String get expandPane => 'Expand pane';

  @override
  String get collapsePane => 'Collapse pane';

  @override
  String get showOptions => 'Show Options';

  @override
  String get hideOptions => 'Hide Options';

  @override
  String get canvasFormat => 'Canvas Format';

  @override
  String get framing => 'Framing';

  @override
  String get background => 'Background';

  @override
  String get size => 'Size';

  @override
  String get padding => 'Padding';

  @override
  String get roundedCorners => 'Rounded corners';

  @override
  String get backgroundImage => 'Background Image';

  @override
  String get moreImages => 'More images';

  @override
  String get pickAnImage => 'Pick an image';

  @override
  String get backgroundColor => 'Background Color';

  @override
  String get moreColors => 'More colors';

  @override
  String get pickColor => 'Pick a color';

  @override
  String get gotIt => 'Got it';

  @override
  String get increase => 'Increase';

  @override
  String get decrease => 'Decrease';

  @override
  String get showCursor => 'Show Cursor';

  @override
  String get toggleCursorVisibility => 'Toggle cursor visibility';

  @override
  String get cursorSize => 'Cursor Size';

  @override
  String get cursor => 'Cursor';

  @override
  String get zoomInEffect => 'Zoom in effect';

  @override
  String get manageZoomEffects => 'Manage zoom in effects';

  @override
  String get zoom => 'Zoom';

  @override
  String get intensity => 'Intensity';

  @override
  String get layout => 'Layout';

  @override
  String get loudness => 'Loudness';

  @override
  String get placement => 'Placement';

  @override
  String get motion => 'Motion';

  @override
  String get zoomResponse => 'Zoom Response';

  @override
  String get fixed => 'Fixed';

  @override
  String get scaleWithZoom => 'Scale with Zoom';

  @override
  String get zoomScale => 'Zoom Scale';

  @override
  String get intro => 'Intro';

  @override
  String get outro => 'Outro';

  @override
  String get introDuration => 'Intro Duration';

  @override
  String get outroDuration => 'Outro Duration';

  @override
  String get fade => 'Fade';

  @override
  String get pop => 'Pop';

  @override
  String get slide => 'Slide';

  @override
  String get shrink => 'Shrink';

  @override
  String get zoomEmphasis => 'Zoom Emphasis';

  @override
  String get pulse => 'Pulse';

  @override
  String get pulseStrength => 'Pulse Strength';

  @override
  String get cameraNoAssetNotice =>
      'No separate camera asset was recorded for this clip.';

  @override
  String get cameraPlacementHelper =>
      'Adjust or move camera position on screen.';

  @override
  String get cameraBackgroundBehindHint =>
      'Background layout fills the full canvas. Choose a point or drag the handle to switch back to an overlay position.';

  @override
  String get topLeft => 'Top left';

  @override
  String get topCenter => 'Top center';

  @override
  String get topRight => 'Top right';

  @override
  String get centerLeft => 'Center left';

  @override
  String get centerRight => 'Center right';

  @override
  String get bottomLeft => 'Bottom left';

  @override
  String get bottomCenter => 'Bottom center';

  @override
  String get bottomRight => 'Bottom right';

  @override
  String get refreshDevicesTooltip => 'Refresh devices (⌘R)';

  @override
  String get copyLastPathTooltip => 'Copy last path';

  @override
  String get timeline => 'Timeline';

  @override
  String get newRecording => 'New recording';

  @override
  String get newRecordingTooltip =>
      'Discard current preview and start a new recording';

  @override
  String get startNewRecordingTitle => 'Start a new recording?';

  @override
  String get startNewRecordingBody =>
      'This will close the current preview and remove any unsaved edits. Export first if you want to keep this recording.';

  @override
  String get keepEditing => 'Keep Editing';

  @override
  String get discardPreview => 'Discard preview';

  @override
  String get play => 'Play';

  @override
  String get pausePlayback => 'Pause';

  @override
  String get markers => 'Markers';

  @override
  String get lanes => 'Lanes';

  @override
  String get snap => 'Snap';

  @override
  String get zoomBehavior => 'Zoom behavior';

  @override
  String get zoomFollowCursor => 'Follow cursor';

  @override
  String get zoomFixedTarget => 'Fixed target';

  @override
  String get zoomCursorStaticHint =>
      'Cursor does not move in this range. Fixed target gives a visible zoom.';

  @override
  String get zoomAddSegment => 'Add zoom segment';

  @override
  String get zoomAddOne => 'Add one';

  @override
  String get zoomKeepAdding => 'Keep adding';

  @override
  String get zoomKeepAddingTooltip => 'Keep adding zoom segments';

  @override
  String get zoomAddOneTooltip => 'Add one zoom segment';

  @override
  String get zoomAddOneStatus =>
      'Add one zoom • Drag on the zoom track • Esc to cancel';

  @override
  String get zoomKeepAddingStatus =>
      'Keep adding zooms • Drag on the zoom track • Esc to exit';

  @override
  String get zoomMoveStatus => 'Moving selected zoom';

  @override
  String get zoomTrimStartStatus => 'Trimming zoom start';

  @override
  String get zoomTrimEndStatus => 'Trimming zoom end';

  @override
  String get zoomBandSelectStatus => 'Selecting zooms';

  @override
  String get zoomSelectionTools => 'Selection tools';

  @override
  String get zoomDeleteSelectedOne => 'Delete selected segment';

  @override
  String zoomDeleteSelectedMany(int count) {
    return 'Delete $count segments';
  }

  @override
  String get zoomSelectAfterPlayhead => 'Select after playhead';

  @override
  String get zoomClearSelection => 'Clear selection';

  @override
  String zoomSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get zoomSelectAllVisible => 'Select all visible';

  @override
  String get zoomUndoLastAction => 'Undo last action';

  @override
  String get zoomSelectionCleared => 'Selection cleared';

  @override
  String get zoomChangeSelectionRange => 'Change selection range';

  @override
  String stopIn(Object value) {
    return 'Stop in $value';
  }

  @override
  String get recording => 'Recording';

  @override
  String get classic43 => 'Classic (4:3)';

  @override
  String get classic => 'Classic';

  @override
  String get square11 => 'Square (1:1)';

  @override
  String get youtube169 => 'YouTube (16:9)';

  @override
  String get reel916 => 'Reel (9:16)';

  @override
  String get wide => 'Wide';

  @override
  String get vertical => 'Vertical';

  @override
  String get vertical4k => 'Vertical 4K (2160x3840)';

  @override
  String get canvasAspect => 'Canvas Aspect';

  @override
  String get fitMode => 'Fit Mode';

  @override
  String get fit => 'Fit';

  @override
  String get fill => 'Fill';

  @override
  String get recordingInProgress => 'RECORDING IN PROGRESS';

  @override
  String get recordingPaused => 'RECORDING PAUSED';

  @override
  String get readyToRecord => 'READY TO RECORD';

  @override
  String get pause => 'PAUSE';

  @override
  String get resume => 'RESUME';

  @override
  String get paused => 'Paused';

  @override
  String get stop => 'STOP';

  @override
  String get startRecording => 'START RECORDING';

  @override
  String get loading => 'Loading…';

  @override
  String hoursShort(Object value) {
    return '$value h';
  }

  @override
  String minutesShort(Object value) {
    return '$value min';
  }

  @override
  String get off => 'Off';

  @override
  String get whileRecording => 'While recording';

  @override
  String get alwaysOn => 'Always on';

  @override
  String get general => 'General';

  @override
  String get settingsWorkspace => 'Workspace';

  @override
  String get settingsWorkspaceDescription =>
      'Theme, language, and save-folder behavior.';

  @override
  String get settingsStorage => 'Storage';

  @override
  String get settingsStorageDescription =>
      'Recording space, internal usage, and disk health.';

  @override
  String get settingsShortcutsDescription =>
      'Customize keyboard shortcuts and resolve conflicts.';

  @override
  String get settingsLicense => 'License';

  @override
  String get settingsLicenseDescription =>
      'Plan status, entitlement, device link, and upgrade actions.';

  @override
  String get settingsPermissions => 'Permissions';

  @override
  String get settingsPermissionsDescription =>
      'Access status and quick links to System Settings.';

  @override
  String get settingsDiagnostics => 'Diagnostics';

  @override
  String get settingsDiagnosticsDescription =>
      'Logs and troubleshooting utilities.';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsAboutDescription =>
      'Version information, support, and legal links.';

  @override
  String get permissionsTitle => 'Permissions';

  @override
  String get permissionsHelpText =>
      'Review which permissions Clingfy can use and jump directly to the relevant System Settings pane.';

  @override
  String get permissionsRefreshStatus => 'Refresh Status';

  @override
  String get permissionsGranted => 'Granted';

  @override
  String get permissionsNotGranted => 'Not granted';

  @override
  String get permissionsRequired => 'Required';

  @override
  String get permissionsOptional => 'Optional';

  @override
  String get permissionsScreenRecording => 'Screen Recording';

  @override
  String get permissionsMicrophone => 'Microphone';

  @override
  String get permissionsCamera => 'Camera';

  @override
  String get permissionsAccessibility => 'Accessibility';

  @override
  String get permissionsScreenRecordingHelp =>
      'Required to capture a display, window, or selected screen area.';

  @override
  String get permissionsMicrophoneHelp =>
      'Lets Clingfy include your voice narration in recordings.';

  @override
  String get permissionsCameraHelp =>
      'Lets Clingfy show your face-cam overlay while recording.';

  @override
  String get permissionsAccessibilityHelp =>
      'Used for click highlights and cursor-aware effects.';

  @override
  String get permissionsChangedHint =>
      'If you change a permission in System Settings, return to Clingfy and refresh this page to see the latest status.';

  @override
  String get permissionsGrantAccess => 'Grant Access';

  @override
  String get settingsLinks => 'Links';

  @override
  String get appTheme => 'App Theme';

  @override
  String get appThemeDescription => 'Choose your preferred appearance';

  @override
  String get systemDefault => 'System Default';

  @override
  String get light => 'Light';

  @override
  String get dark => 'Dark';

  @override
  String get appLanguage => 'App Language';

  @override
  String get appLanguageDescription =>
      'Select the language for the application';

  @override
  String get english => 'English';

  @override
  String get arabic => 'Arabic';

  @override
  String get romanian => 'Romanian';

  @override
  String get exportVideo => 'Export Video';

  @override
  String get close => 'Close';

  @override
  String get cancel => 'Cancel';

  @override
  String get enterVideoName => 'Enter a name for your video:';

  @override
  String get filename => 'Filename';

  @override
  String get matchSystem => 'Match system';

  @override
  String get keyboardShortcuts => 'Keyboard Shortcuts';

  @override
  String get toggleRecording => 'Toggle Recording';

  @override
  String get refreshDevices => 'Refresh Devices';

  @override
  String get toggleActionBar => 'Toggle Action Bar';

  @override
  String get cycleOverlayMode => 'Cycle Overlay Mode';

  @override
  String get pressKeyToCapture => 'Press a key combination… Esc to cancel';

  @override
  String shortcutCollision(Object action) {
    return 'Shortcut already used by $action';
  }

  @override
  String get resetShortcuts => 'Reset Shortcuts';

  @override
  String get countdown => 'Countdown';

  @override
  String seconds(Object value) {
    return '$value s';
  }

  @override
  String get recordingFolderBehavior => 'Recording folder behavior';

  @override
  String get openFolderAfterStop => 'Open folder after stopping recording';

  @override
  String get openFolderAfterExport => 'Open folder after exporting video';

  @override
  String get confirmations => 'Confirmations';

  @override
  String get warnBeforeClosingUnexportedRecording =>
      'Warn before closing an unexported recording';

  @override
  String get warnBeforeClosingUnexportedRecordingDescription =>
      'Show a confirmation before closing the current recording if it has not been exported yet.';

  @override
  String get closeUnexportedRecordingTitle =>
      'Close recording without exporting?';

  @override
  String get closeUnexportedRecordingMessage =>
      'This recording hasn’t been exported yet. If you close it now, you’ll lose access to it in the current session.';

  @override
  String get closeWithoutExporting => 'Close Without Exporting';

  @override
  String get doNotShowAgain => 'Do not show again';

  @override
  String get aboutThisApp => 'About this app';

  @override
  String get aboutClingfy => 'About Clingfy';

  @override
  String version(Object value) {
    return 'Version $value';
  }

  @override
  String get aboutDeveloperModeEnabled => 'Developer mode enabled';

  @override
  String get aboutDeveloperModeDisabled => 'Developer mode disabled';

  @override
  String get aboutBuildMetadata => 'BUILD METADATA';

  @override
  String get aboutBuildCommit => 'Commit';

  @override
  String get aboutBuildBranch => 'Branch';

  @override
  String get aboutBuildId => 'Build ID';

  @override
  String get aboutBuildDate => 'Built';

  @override
  String get checkForUpdates => 'Check for Updates';

  @override
  String get escToCancel => 'Esc to cancel';

  @override
  String get menuFile => 'File';

  @override
  String get menuView => 'View';

  @override
  String get showActionBar => 'Show Action Bar';

  @override
  String get recordingSetupNeedsAttention =>
      'Recording setup needs your attention';

  @override
  String get storageOverviewTitle => 'Recording safety';

  @override
  String get storageOverviewDescription =>
      'Monitor system free space and Clingfy workspace usage to avoid failed recordings.';

  @override
  String get storageSystemTitle => 'System storage';

  @override
  String get storageSystemDescription =>
      'The drive backing Clingfy\'s active capture destination.';

  @override
  String get storageClingfyTitle => 'Clingfy storage';

  @override
  String get storageClingfyDescription =>
      'Internal recordings, temporary captures, and logs.';

  @override
  String get storageActionsTitle => 'Actions';

  @override
  String get storagePathsTitle => 'Paths';

  @override
  String get storageHealthy => 'Healthy';

  @override
  String get storageWarning => 'Warning';

  @override
  String get storageCritical => 'Critical';

  @override
  String get storageHealthyMessage =>
      'Your system has enough free space for normal recording.';

  @override
  String get storageWarningMessage =>
      'Free space is getting low. Long recordings may fail.';

  @override
  String get storageCriticalMessage =>
      'Recording is blocked until more disk space is available.';

  @override
  String get storageRefresh => 'Refresh';

  @override
  String get storageOpenRecordingsFolder => 'Open recordings folder';

  @override
  String get storageOpenTempFolder => 'Open temp folder';

  @override
  String get storageClearCachedRecordings => 'Clear cached recordings';

  @override
  String get storageClearCachedRecordingsConfirmTitle =>
      'Clear cached recordings?';

  @override
  String get storageClearCachedRecordingsConfirmMessage =>
      'This removes Clingfy\'s internal recording copies and sidecars. Exported recordings are not deleted, and this action cannot be undone.';

  @override
  String get storageClearCachedRecordingsConfirmAction => 'Clear recordings';

  @override
  String storageClearCachedRecordingsSuccess(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Removed $count cached recordings.',
      one: 'Removed 1 cached recording.',
    );
    return '$_temp0';
  }

  @override
  String get storageStatusLabel => 'Status';

  @override
  String get storageTotalSpace => 'Total';

  @override
  String get storageUsedSpace => 'Used';

  @override
  String get storageFreeSpace => 'Free';

  @override
  String get storageRecordings => 'Recordings';

  @override
  String get storageTemp => 'Temp';

  @override
  String get storageLogs => 'Logs';

  @override
  String get storageClingfyTotal => 'Total Clingfy usage';

  @override
  String get storageRecordingsPath => 'Recordings folder';

  @override
  String get storageTempPath => 'Temp folder';

  @override
  String get storageLogsPath => 'Logs folder';

  @override
  String get storageActionFailed => 'Storage action failed.';

  @override
  String storageFreeNow(String value) {
    return 'Free now: $value';
  }

  @override
  String get missingRequiredPermission => 'Missing required permission';

  @override
  String get missingOptionalPermissionsForRequestedFeatures =>
      'Missing optional permissions for requested features';

  @override
  String get grantPermissions => 'Grant permissions';

  @override
  String get recordWithoutMissingFeatures => 'Record without missing features';

  @override
  String get storagePreflightTitle => 'Storage needs your attention';

  @override
  String get storagePreflightCriticalIntro =>
      'Clingfy detected critically low free space on the active recording drive. Recording is blocked to avoid failed captures.';

  @override
  String get storagePreflightWarningIntro =>
      'Free space is getting low. Long recordings may fail before they finish.';

  @override
  String get storageAvailableNow => 'Available now';

  @override
  String get storageRecordingBlockedBelow => 'Recording is blocked below';

  @override
  String get storageRecommendedFreeSpace => 'Recommended free space';

  @override
  String get openStorageSettings => 'Open Storage Settings';

  @override
  String get recordAnyway => 'Record anyway';

  @override
  String get storageBypassAndRecord => 'Bypass and record';

  @override
  String get cameraForFaceCam => 'Camera for Face Cam';

  @override
  String get microphoneForVoice => 'Microphone for Voice';

  @override
  String get accessibilityForCursorHighlight =>
      'Accessibility for Cursor Highlight';

  @override
  String get menuRecord => 'Record';

  @override
  String get unknown => 'Unknown';

  @override
  String get none => 'None';

  @override
  String get appDescription => 'A simple, powerful screen recorder for macOS.';

  @override
  String get visitWebsite => 'Visit Website';

  @override
  String get contactSupport => 'Contact Support';

  @override
  String get privacyPolicy => 'Privacy Policy';

  @override
  String get termsOfService => 'Terms of Service';

  @override
  String get locationLabel => 'Location:';

  @override
  String get changeButtonLabel => 'Change...';

  @override
  String get cancelExport => 'Cancel Export';

  @override
  String get cancelExportConfirm =>
      'Are you sure you want to stop the export process?';

  @override
  String get keepExporting => 'Keep Exporting';

  @override
  String get stopExport => 'Stop Export';

  @override
  String get runInBackground => 'Run in background';

  @override
  String get hideProgress => 'Hide progress';

  @override
  String get showProgress => 'Show progress';

  @override
  String get cancelingExport => 'Canceling export...';

  @override
  String get exportAlreadyInProgress => 'An export is already in progress.';

  @override
  String get errAlreadyRecording => 'A recording is already in progress.';

  @override
  String get errNoWindowSelected => 'Please select a window to record.';

  @override
  String get errNoAreaSelected => 'Please select an area to record first.';

  @override
  String get errTargetError => 'Unable to determine what should be recorded.';

  @override
  String get errNotRecording => 'No active recording to stop.';

  @override
  String get errInvalidRecordingState =>
      'That action is not available in the current recording state.';

  @override
  String get errPauseResumeUnsupported =>
      'Pause and resume are not supported for the current recording setup.';

  @override
  String get errUnknownAudioDevice =>
      'Selected audio device is no longer available.';

  @override
  String get errBadQuality => 'Invalid recording quality.';

  @override
  String get errScreenRecordingPermission =>
      'Enable Screen Recording in System Settings > Privacy & Security > Screen Recording, then try again.';

  @override
  String get errWindowUnavailable =>
      'The selected window is no longer available. Refresh the list and pick it again.';

  @override
  String errRecordingError(Object error) {
    return 'A recording error occurred: $error';
  }

  @override
  String errOutputUrlError(Object error) {
    return 'Could not create output file: $error';
  }

  @override
  String get errAccessibilityPermissionRequired =>
      'Enable Accessibility for cursor highlight in System Settings, then relaunch.';

  @override
  String get errMicrophonePermissionRequired =>
      'Enable microphone access in System Settings > Privacy & Security > Microphone, then try again.';

  @override
  String get recordingSelectedMicFallbackWarning =>
      'Selected microphone couldn’t be used. Recording started with the system default microphone.';

  @override
  String get recordingSelectedMicFallbackFailure =>
      'Selected microphone couldn’t be used for recording. Choose another microphone or turn microphone recording off.';

  @override
  String errExportError(Object error) {
    return 'An error occurred during export: $error';
  }

  @override
  String get errCameraPermissionDenied =>
      'Enable camera in System Settings > Privacy & Security > Camera.';

  @override
  String get shape => 'Shape';

  @override
  String get squircle => 'Squircle';

  @override
  String get circle => 'Circle';

  @override
  String get roundedRect => 'Rounded Rect';

  @override
  String get square => 'Square';

  @override
  String get hexagon => 'Hexagon';

  @override
  String get star => 'Star';

  @override
  String cornerRoundness(Object value) {
    return 'Corner Roundness: $value%';
  }

  @override
  String sizePx(Object value) {
    return 'Size: ${value}px';
  }

  @override
  String opacityPercent(Object value) {
    return 'Opacity: $value%';
  }

  @override
  String get opacity => 'Opacity';

  @override
  String get mirrorSelfView => 'Mirror self-view';

  @override
  String get chromaKey => 'Chroma key (green screen)';

  @override
  String keyTolerance(Object value) {
    return 'Key Tolerance: $value%';
  }

  @override
  String get keyToleranceLabel => 'Key Tolerance';

  @override
  String get chromaKeyColor => 'Chroma key color';

  @override
  String get pickChromaKeyColor => 'Pick chroma key color';

  @override
  String get targetColorToRemove => 'Target color to remove';

  @override
  String get position => 'Position';

  @override
  String get customPosition => 'Custom position';

  @override
  String get customPositionHint =>
      'Dragged manually. Select a corner to snap back.';

  @override
  String get shadow => 'Shadow';

  @override
  String get border => 'Border';

  @override
  String get pickBorderColor => 'Pick border color';

  @override
  String borderWidth(Object value) {
    return 'Border width: $value px';
  }

  @override
  String get borderWidthLabel => 'Border width';

  @override
  String get diagnosticsTitle => 'Diagnostics';

  @override
  String get diagnosticsHelpText =>
      'If something goes wrong, open the logs folder and send today\'s log file to support.';

  @override
  String get openLogsFolder => 'Open Logs Folder';

  @override
  String get revealTodayLog => 'Reveal Today\'s Log File';

  @override
  String get copyLogPath => 'Copy Path';

  @override
  String get errVideoFileMissing => 'Recording file was moved or deleted.';

  @override
  String get errCursorFileMissing =>
      'Cursor data is missing. Cursor effects are disabled.';

  @override
  String get errExportInputMissing =>
      'Recording file not found. It may have been moved or deleted.';

  @override
  String get errAssetInvalid => 'Failed to prepare video preview.';

  @override
  String get applyEffects => 'Apply Effects';

  @override
  String get recordingSaved => 'Recording saved:';

  @override
  String get externalProjectOpenBlocked =>
      'Finish the current recording or preview transition before opening another project.';

  @override
  String get externalProjectOpenFailed =>
      'Couldn\'t open that Clingfy project.';

  @override
  String get exportSuccess => 'Export successful:';

  @override
  String get open => 'Open';

  @override
  String get cursorDataMissing => 'Cursor data missing';

  @override
  String get voiceBoost => 'Voice Boost';

  @override
  String get audioGain => 'Audio Gain';

  @override
  String get volume => 'Volume';

  @override
  String get micInputLevel => 'Mic input level';

  @override
  String get micInputIndicatorDisabledTooltip =>
      'Select a microphone to preview input level.';

  @override
  String micInputIndicatorLiveTooltip(String dbfs) {
    return 'Mic input level: $dbfs dBFS';
  }

  @override
  String get micInputIndicatorLowTooltip =>
      'Mic input is very low. Raise input level or move closer to the mic.';

  @override
  String get noMicAudioFound => 'No mic audio track found';

  @override
  String get autoNormalizeOnExport => 'Auto-normalize on export';

  @override
  String get targetLoudness => 'Target loudness';

  @override
  String get selectCameraHint =>
      'Select a camera to configure overlay settings';

  @override
  String get closePreview => 'Close Preview';

  @override
  String get preparingPreview => 'Preparing preview...';

  @override
  String get menuStartRecording => 'Start Recording';

  @override
  String get menuStopRecording => 'Stop Recording';

  @override
  String get menuOpenApp => 'Open Clingfy';

  @override
  String get menuQuit => 'Quit Clingfy';

  @override
  String get captureSettings => 'Capture Settings';

  @override
  String get captureSettingsDescription =>
      'Configure how screen capture behaves.';

  @override
  String get excludeRecorderAppFromCapture =>
      'Exclude recorder app from capture';

  @override
  String get excludeRecorderAppFromCaptureDescription =>
      'When enabled, the recorder window is hidden from recordings. Disable to include it (useful for tutorials about this app).';

  @override
  String get ok => 'OK';

  @override
  String get copy => 'Copy';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String get loadingYourSettings => 'Loading your settings...';

  @override
  String get renderingErrorFallbackMessage =>
      'A rendering error occurred.\nCheck logs for details.';

  @override
  String get debugResetPreferencesTitle => 'Reset preferences?';

  @override
  String get debugResetPreferencesMessage => 'This clears all saved settings.';

  @override
  String get debugResetPreferencesConfirm => 'Reset';

  @override
  String get debugResetPreferencesSemanticLabel => 'Reset preferences (Debug)';

  @override
  String get diagnosticsLogFileNotFound =>
      'Log file not found. Try reproducing the issue first.';

  @override
  String get diagnosticsLogFileUnavailable =>
      'Log file path is unavailable right now.';

  @override
  String get diagnosticsActionFailed => 'Could not complete that action.';

  @override
  String get diagnosticsLogRevealed => 'Revealed today\'s log file.';

  @override
  String get recordingSystemAudio => 'System audio';

  @override
  String get recordingExcludeMicFromSystemAudio =>
      'Exclude my mic from system audio';

  @override
  String get restartApp => 'Restart App';

  @override
  String get permissionsOnboardingWelcomeRail => 'Welcome';

  @override
  String get permissionsOnboardingMicCameraRail => 'Mic + Camera';

  @override
  String permissionsOnboardingStepLabel(int current) {
    return 'Step $current of 4';
  }

  @override
  String get permissionsOnboardingWelcomeTitle => 'Welcome to Clingfy';

  @override
  String get permissionsOnboardingWelcomeSubtitle =>
      'A quick studio setup and you’re ready to record in minutes.';

  @override
  String get permissionsOnboardingTrustLocalFirst =>
      'Local-first: your recordings stay on your Mac.';

  @override
  String get permissionsOnboardingTrustPermissionControl =>
      'You control permissions anytime in System Settings.';

  @override
  String get permissionsOnboardingFeatureExportsTitle => 'Crisp 4K+ exports';

  @override
  String get permissionsOnboardingFeatureExportsSubtitle =>
      'Presets for YouTube, reels, and more.';

  @override
  String get permissionsOnboardingFeatureZoomTitle =>
      'Zoom-follow + cursor effects';

  @override
  String get permissionsOnboardingFeatureZoomSubtitle =>
      'Help viewers track what matters.';

  @override
  String get permissionsOnboardingScreenTitle => 'Screen Recording (Required)';

  @override
  String get permissionsOnboardingScreenSubtitle =>
      'macOS requires this before any recording can start. Takes about 15 seconds.';

  @override
  String get permissionsOnboardingWhyAreYouAsking => 'Why are you asking?';

  @override
  String get permissionsOnboardingWhyIsThisNeeded => 'Why is this needed?';

  @override
  String get permissionsOnboardingWhyScreenTitle => 'Why Screen Recording?';

  @override
  String get permissionsOnboardingWhyScreenSubtitle =>
      'This permission is required by macOS to capture pixels from your screen.';

  @override
  String get permissionsOnboardingWhyScreenBullet1 =>
      'Needed for full display, window capture, and custom area recording.';

  @override
  String get permissionsOnboardingWhyScreenBullet2 =>
      'Clingfy records locally; exporting is something you initiate.';

  @override
  String get permissionsOnboardingWhyScreenBullet3 =>
      'You can disable it anytime in System Settings.';

  @override
  String get permissionsOnboardingWhyScreenFooter =>
      'If macOS shows a toggle for Clingfy, make sure it is on.';

  @override
  String get permissionsOnboardingScreenTrustLine1 =>
      'Local-first: recordings stay on your Mac.';

  @override
  String get permissionsOnboardingScreenTrustLine2 =>
      'You’re always in control — change this anytime.';

  @override
  String get permissionsOnboardingRestartHint =>
      'If macOS shows a toggle, make sure it\'s on. You might need to restart Clingfy.';

  @override
  String get permissionsOnboardingVoiceCameraTitle =>
      'Voice & Face-cam (Optional)';

  @override
  String get permissionsOnboardingVoiceCameraSubtitle =>
      'Recommended for tutorials, but you can skip this and enable it later.';

  @override
  String get permissionsOnboardingMicrophoneDescription =>
      'For narration and voice boost.';

  @override
  String get permissionsOnboardingEnableMic => 'Enable Mic';

  @override
  String get permissionsOnboardingWhyMicrophoneTitle => 'Why Microphone?';

  @override
  String get permissionsOnboardingWhyMicrophoneSubtitle =>
      'So your recordings can include your voice narration.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet1 =>
      'Used only when you enable mic recording.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet2 =>
      'You can pick input devices inside the app.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet3 =>
      'You can revoke this anytime.';

  @override
  String get permissionsOnboardingCameraDescription =>
      'Show your face in a customizable bubble.';

  @override
  String get permissionsOnboardingEnableCamera => 'Enable Camera';

  @override
  String get permissionsOnboardingWhyCameraTitle => 'Why Camera?';

  @override
  String get permissionsOnboardingWhyCameraSubtitle =>
      'For face-cam overlays (optional).';

  @override
  String get permissionsOnboardingWhyCameraBullet1 =>
      'Only used when you enable the camera bubble.';

  @override
  String get permissionsOnboardingWhyCameraBullet2 =>
      'You can turn it off anytime during recording.';

  @override
  String get permissionsOnboardingWhyCameraBullet3 =>
      'You can revoke this anytime.';

  @override
  String get permissionsOnboardingAudioTrustLine1 =>
      'Optional step — you can record without mic or camera.';

  @override
  String get permissionsOnboardingAudioTrustLine2 =>
      'Enable them later anytime from app settings.';

  @override
  String get permissionsOnboardingCursorTitle => 'Cursor Magic (Optional)';

  @override
  String get permissionsOnboardingCursorSubtitle =>
      'Enable click highlights and smoother cursor motion for viewers.';

  @override
  String get permissionsOnboardingAccessibilityDescription =>
      'Used to detect mouse clicks for cursor effects.';

  @override
  String get permissionsOnboardingCheck => 'Check';

  @override
  String get permissionsOnboardingWhyAccessibilityTitle => 'Why Accessibility?';

  @override
  String get permissionsOnboardingWhyAccessibilitySubtitle =>
      'macOS groups mouse-event access under Accessibility permissions.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet1 =>
      'Used for click highlights and Cursor Magic effects.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet2 =>
      'Recommended for tutorials and demos, but not required to record.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet3 =>
      'You can revoke it anytime in System Settings.';

  @override
  String get permissionsOnboardingCursorTrustLine1 =>
      'Optional step — your recordings work without it.';

  @override
  String get permissionsOnboardingCursorTrustLine2 =>
      'You can enable Cursor Magic later whenever you want.';

  @override
  String get permissionsOnboardingSkipForNow => 'Skip for now';

  @override
  String get permissionsOnboardingBack => 'Back';

  @override
  String get permissionsOnboardingNext => 'Next';

  @override
  String get permissionsOnboardingLetsRecord => 'Let’s Record! 🚀';

  @override
  String get quickTour => 'Quick Tour';

  @override
  String get back => 'Back';

  @override
  String get next => 'Next';

  @override
  String get skip => 'Skip';

  @override
  String get done => 'Done';

  @override
  String homeGuideStepCounter(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String get homeGuideSidebarTitle =>
      'This rail keeps the whole recording workflow within reach.';

  @override
  String get homeGuideSidebarBody =>
      'Use these buttons to switch setup sections, open Help, and jump to settings without leaving the recorder.';

  @override
  String get homeGuideCaptureSourceTitle => 'Choose what Clingfy records here.';

  @override
  String get homeGuideCaptureSourceBody =>
      'Pick a display, a single window, or a custom area before you start recording.';

  @override
  String get homeGuideCameraTitle => 'Turn face cam on only when you need it.';

  @override
  String get homeGuideCameraBody =>
      'Select a camera, then adjust the overlay later if you want your face on tutorials or demos.';

  @override
  String get homeGuideOutputTitle =>
      'Set recording defaults before you hit record.';

  @override
  String get homeGuideOutputBody =>
      'Countdown and auto-stop live here so each recording starts the way you expect.';

  @override
  String get homeGuideStartRecordingTitle =>
      'This is the main recording control.';

  @override
  String get homeGuideStartRecordingBody =>
      'When your source looks right, start here. The same area lets you pause or stop later.';

  @override
  String get homeGuideHelpTitle => 'Replay this tour anytime from Help.';

  @override
  String get homeGuideHelpBody =>
      'Open Help for a quick refresher or jump to About when you need version and support details.';

  @override
  String get homeGuideReplayUnavailable =>
      'Return to recording setup to replay the quick tour.';

  @override
  String get window => 'Window';

  @override
  String get area => 'Area';

  @override
  String get mic => 'Mic';

  @override
  String get system => 'System';

  @override
  String get update => 'Update';

  @override
  String get screen => 'Screen';

  @override
  String get app => 'App';

  @override
  String get selectDisplay => 'Select Display';

  @override
  String get selectWindow => 'Select Window';

  @override
  String get selectMicrophone => 'Select Microphone';

  @override
  String get selectCamera => 'Select Camera';

  @override
  String get unknownDisplay => 'Unknown Display';

  @override
  String get unknownWindow => 'Unknown Window';

  @override
  String get unknownMic => 'Unknown Mic';

  @override
  String get unknownCamera => 'Unknown Camera';

  @override
  String get noCamera => 'No camera';

  @override
  String get doNotRecordAudio => 'Do not record audio';

  @override
  String get stoppingEllipsis => 'Stopping...';

  @override
  String get pauseRecording => 'Pause recording';

  @override
  String get resumeRecording => 'Resume recording';

  @override
  String get recordingInProgressLabel => 'Recording in progress';

  @override
  String get recordingPausedLabel => 'Recording paused';

  @override
  String get stoppingRecording => 'Stopping recording';

  @override
  String get recordingIndicatorHelpPause =>
      'Primary action pauses recording. Secondary stop control stops recording.';

  @override
  String get recordingIndicatorHelpResume =>
      'Primary action resumes recording. Secondary stop control stops recording.';

  @override
  String get recordingIndicatorHelpStopping => 'Recording is stopping.';

  @override
  String get defaultExportFileNameLabel => 'Export';

  @override
  String get defaultClipFileNameLabel => 'Clip';

  @override
  String get licenseInitializing => 'Initializing...';

  @override
  String get licenseInternetRequired => 'Internet required to verify license.';

  @override
  String get licenseOfflineCached => 'Offline mode (cached)';

  @override
  String get licenseValidationFailed => 'Could not validate license.';

  @override
  String get licenseTrialConsumptionFailed => 'Could not sync trial usage.';

  @override
  String get licenseNetworkUnavailableWhileConsumingTrial =>
      'Network unavailable while syncing trial usage.';

  @override
  String get licenseNetworkUnavailableWhileDeactivatingDevice =>
      'Network unavailable while deactivating device.';

  @override
  String get licenseValidated => 'License validated.';

  @override
  String get licenseNotEntitled => 'This license does not unlock Pro features.';
}
