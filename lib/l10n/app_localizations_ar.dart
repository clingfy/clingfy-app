// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'Clingfy — مسجل الشاشة';

  @override
  String get record => 'تسجيل';

  @override
  String get output => 'المخرجات';

  @override
  String get settings => 'الإعدادات';

  @override
  String get tabScreenAudio => 'Screen & Audio';

  @override
  String get tabFaceCam => 'Face Cam';

  @override
  String get screenTarget => 'هدف الشاشة';

  @override
  String get recordTarget => 'هدف التسجيل';

  @override
  String get captureSource => 'مصدر الالتقاط';

  @override
  String get chosenScreen => 'الشاشة المختارة';

  @override
  String get appWindowScreen => 'شاشة نافذة التطبيق';

  @override
  String get specificAppWindow => 'نافذة تطبيق معينة';

  @override
  String get screenUnderMouse => 'الشاشة تحت الماوس (عند البدء)';

  @override
  String get followMouse => 'تتبع الماوس (تقسيم الملفات)';

  @override
  String get followMouseNote =>
      'ملاحظة: مع المشفر الحالي، سيتم تقسيم التسجيل عندما ينتقل الماوس إلى شاشة أخرى.';

  @override
  String get display => 'العرض';

  @override
  String get refreshDisplays => 'تحديث الشاشات (⌘R)';

  @override
  String get screenToRecord => 'الشاشة المراد تسجيلها';

  @override
  String get mainDisplay => 'الشاشة الرئيسية';

  @override
  String get appWindow => 'نافذة التطبيق';

  @override
  String get refreshWindows => 'تحديث النوافذ';

  @override
  String get windowToRecord => 'النافذة المراد تسجيلها';

  @override
  String get selectAppWindow => 'اختر نافذة التطبيق';

  @override
  String get refreshWindowHint =>
      'قم بالتحديث إذا لم تظهر النافذة، ثم اخترها من الأعلى.';

  @override
  String get areaRecording => 'تسجيل منطقة';

  @override
  String get pickArea => 'اختر المنطقة...';

  @override
  String get changeArea => 'تغيير المنطقة';

  @override
  String get revealArea => 'إظهار';

  @override
  String get clearArea => 'احذف الصورة';

  @override
  String get areaRecordingHelper => 'تسجيل منطقة مستطيلة مخصصة من الشاشة.';

  @override
  String get noAreaSelected => 'لم يتم اختيار منطقة';

  @override
  String selectedAreaAt(
    Object height,
    Object id,
    Object width,
    Object x,
    Object y,
  ) {
    return 'العرض $id: ${width}x$height عند ($x, $y)';
  }

  @override
  String get audio => 'الصوت';

  @override
  String get pointer => 'المؤشر';

  @override
  String get refreshAudio => 'تحديث أجهزة الصوت (⌘R)';

  @override
  String get inputDevice => 'جهاز الإدخال';

  @override
  String get noAudio => 'بدون صوت';

  @override
  String get camera => 'الكاميرا';

  @override
  String get refreshCameras => 'تحديث الكاميرات (⌘R)';

  @override
  String get cameraDevice => 'جهاز الكاميرا';

  @override
  String get recordingQuality => 'جودة التسجيل';

  @override
  String get quality => 'الجودة';

  @override
  String get resolution => 'الدقة';

  @override
  String get frameRate => 'Frame Rate';

  @override
  String fps(Object value) {
    return '$value FPS';
  }

  @override
  String get saveLocation => 'موقع الحفظ';

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
  String get auto => 'تلقائي';

  @override
  String get low => 'Low';

  @override
  String get medium => 'Medium';

  @override
  String get high => 'High';

  @override
  String get original => 'Original';

  @override
  String get uhd2k => '2K (1440P)';

  @override
  String get uhd4k => '4K (2160P)';

  @override
  String get uhd8k => '8K (4320P)';

  @override
  String get revealInFinder => 'إظهار في Finder';

  @override
  String get resetToDefault => 'إعادة تعيين للافتراضي';

  @override
  String get openFolder => 'افتح المجلد';

  @override
  String get recordingHighlight => 'توهج عند التسجيل';

  @override
  String get recordingGlowStrength => 'شدة التوهج';

  @override
  String recordingGlowStrengthPercent(Object value) {
    return 'شدة التوهج: $value%';
  }

  @override
  String get chooseSaveFolder => 'اختر مجلد الحفظ...';

  @override
  String get defaultSaveFolder => 'الافتراضي: ~/Movies/Clingfy';

  @override
  String get duration => 'المدة';

  @override
  String get startAndStop => 'البدء والإيقاف';

  @override
  String get autoStopAfter => 'إيقاف تلقائي بعد';

  @override
  String get preset => 'جاهز';

  @override
  String get customMinutes => 'مخصص (دقائق)';

  @override
  String get forceLetterbox => 'فرض 16:9 (Letterbox)';

  @override
  String get forceLetterboxSubtitle =>
      'توسيط الشاشة في إطار 16:9 (مثلاً 1080p) مع حواف سوداء.';

  @override
  String get forceLetterboxHint =>
      'يصلح مشكلة الحواف السوداء على YouTube عندما تكون شاشتك عريضة جداً أو ليست بنسبة 16:9.';

  @override
  String get appSettings => 'إعدادات التطبيق';

  @override
  String get appSettingsDescription =>
      'إدارة تفضيلات مساحة العمل، الاختصارات، حالة الترخيص، التشخيصات، وتفاصيل التطبيق.';

  @override
  String get openAppSettings => 'فتح إعدادات التطبيق';

  @override
  String get expandNavigationRail => 'توسيع شريط التنقل';

  @override
  String get compactNavigationRail => 'تصغير شريط التنقل';

  @override
  String get overlayFaceCam => 'الطبقة العلوية (Face-cam)';

  @override
  String get overlayFaceCamVisibility => 'الظهور (Face-cam)';

  @override
  String get visibilityAndPlacement => 'الظهور والموضع';

  @override
  String get appearance => 'المظهر';

  @override
  String get style => 'النمط';

  @override
  String get effects => 'التأثيرات';

  @override
  String get visibility => 'الظهور';

  @override
  String get overlayHint => 'ستظهر الطبقة العلوية عند بدء التسجيل.';

  @override
  String get recordingIndicator => 'مؤشر التسجيل';

  @override
  String get showIndicator => 'إظهار مؤشر التسجيل';

  @override
  String get pinToTopRight => 'تثبيت في أعلى اليمين';

  @override
  String get indicatorHint =>
      'تظهر نقطة “REC” صغيرة أثناء التسجيل. عند تثبيتها، تبقى في أعلى اليمين؛ وإلا يمكنك سحبها.';

  @override
  String get cursorHighlight => 'وضوح تمييز المؤشر';

  @override
  String get cursorHighlightVisibility =>
      'Vizibilitatea evidențierii cursorului';

  @override
  String get cursorHint => 'تمييز المؤشر نشط فقط أثناء التسجيل.';

  @override
  String get appTitleFull => 'Clingfy — مسجل الشاشة';

  @override
  String get recordingPathCopied => 'تم نسخ مسار التسجيل';

  @override
  String get grantAccessibilityPermission =>
      'يرجى منح إذن الوصول (Accessibility) لتمييز المؤشر.';

  @override
  String get openSettings => 'فتح الإعدادات';

  @override
  String get export => 'تصدير';

  @override
  String get exporting => 'جاري التصدير...';

  @override
  String get paywallTitle => 'فتح التصدير الاحترافي';

  @override
  String get paywallSubtitle =>
      'قم بترقية الخطة أو فعّل مفتاح الترخيص للمتابعة في التصدير.';

  @override
  String paywallTrialRemaining(int count) {
    return 'الصادرات التجريبية المتبقية: $count';
  }

  @override
  String get paywallTrialTier => 'خطة تجريبية: صادرات محدودة لتجربة الميزات';

  @override
  String get paywallLifetimeTier =>
      'خطة مدى الحياة: شراء مرة واحدة مع تغطية التحديثات';

  @override
  String get paywallSubscriptionTier => 'خطة اشتراك: وصول مستمر وتحديثات';

  @override
  String get paywallAlreadyHaveKey => 'لديك مفتاح بالفعل؟';

  @override
  String get paywallLicenseKeyHint => 'أدخل مفتاح الترخيص';

  @override
  String get paywallLicenseKeyRequired => 'يرجى إدخال مفتاح الترخيص.';

  @override
  String get paywallActivateKey => 'تفعيل المفتاح';

  @override
  String get paywallActivationFailed => 'فشل تفعيل الترخيص.';

  @override
  String get paywallExportBlocked =>
      'التصدير مقفل. قم بالترقية أو فعّل مفتاحاً للمتابعة.';

  @override
  String get paywallConsumeFailed =>
      'نجح التصدير، لكن فشلت مزامنة الرصيد التجريبي. تحقق من الاتصال.';

  @override
  String get paywallSubtitleStarter =>
      'احصل على صادرات غير محدودة، وبدون علامة مائية، وجميع ميزات Pro.';

  @override
  String paywallSubtitleTrial(int count) {
    return 'لديك $count صادرات مجانية متبقية. قم بالترقية لإزالة القيود.';
  }

  @override
  String get paywallCardMonthlyTitle => 'Pro شهري';

  @override
  String get paywallCardMonthlyPrice => '\$9.99';

  @override
  String get paywallCardMonthlyPeriod => '/ شهر';

  @override
  String get paywallCardMonthlyDescription => 'احصل دائماً على أحدث الميزات.';

  @override
  String get paywallCardMonthlyFeature1 => 'صادرات غير محدودة';

  @override
  String get paywallCardMonthlyFeature2 => 'بدون علامة مائية';

  @override
  String get paywallCardMonthlyFeature3 => 'دعم أولوية';

  @override
  String get paywallCardMonthlyCta => 'اشترك';

  @override
  String get paywallCardLifetimeTitle => 'Pro مدى الحياة';

  @override
  String get paywallCardLifetimePrice => '\$59.99';

  @override
  String get paywallCardLifetimePeriod => 'مرة واحدة';

  @override
  String get paywallCardLifetimeDescription =>
      'امتلك Clingfy للأبد + سنة تحديثات.';

  @override
  String get paywallCardLifetimeFeature1 => 'ملكية دائمة';

  @override
  String get paywallCardLifetimeFeature2 => 'يشمل سنة تحديثات';

  @override
  String get paywallCardLifetimeFeature3 => 'صادرات غير محدودة';

  @override
  String get paywallCardLifetimeFeature4 => 'بدون علامة مائية';

  @override
  String get paywallCardLifetimeCta => 'اشترِ مدى الحياة';

  @override
  String get paywallCardExtensionTitle => 'تمديد التحديثات';

  @override
  String get paywallCardExtensionPrice => '\$19.99';

  @override
  String get paywallCardExtensionPeriod => 'مرة واحدة';

  @override
  String get paywallCardExtensionDescription =>
      'مدد أهلية التحديثات لمدة +12 شهراً.';

  @override
  String get paywallCardExtensionFeature1 => 'إضافة +12 شهراً من التحديثات';

  @override
  String get paywallCardExtensionFeature2 => 'الاحتفاظ بملكية مدى الحياة';

  @override
  String get paywallCardExtensionFeature3 => 'يعمل مع المفتاح الحالي';

  @override
  String get paywallCardExtensionCta => 'مدد التحديثات';

  @override
  String get paywallRecommendedBadge => 'موصى به';

  @override
  String get paywallActivationSuccess => 'تم فتح Pro بنجاح!';

  @override
  String get paywallPricingOpenFailed => 'تعذر فتح صفحة الأسعار.';

  @override
  String get licenseDevicesTitle => 'الترخيص والأجهزة';

  @override
  String get licenseDevicesSubtitle =>
      'إدارة ربط ترخيص هذا الجهاز لنقل الترخيص.';

  @override
  String get licensePlanLabel => 'الخطة';

  @override
  String get licenseDeviceLinked => 'هذا الجهاز مرتبط بمفتاح الترخيص.';

  @override
  String get licenseDeviceNotLinked => 'لا يوجد ترخيص نشط مرتبط بهذا الجهاز.';

  @override
  String get licenseDeactivateButton => 'إلغاء تفعيل هذا الجهاز';

  @override
  String get licenseDeactivateConfirmTitle => 'إلغاء تفعيل هذا الجهاز؟';

  @override
  String get licenseDeactivateConfirmBody =>
      'سيؤدي هذا إلى إلغاء ربط جهاز Mac الحالي من مفتاح الترخيص على الخادم.';

  @override
  String get licenseDeactivateConfirmAction => 'إلغاء التفعيل';

  @override
  String get licenseDeactivateSuccess => 'تم إلغاء تفعيل الجهاز بنجاح.';

  @override
  String get licenseDeactivateFailed => 'تعذر إلغاء تفعيل هذا الجهاز حالياً.';

  @override
  String get licenseDeactivateUnavailable =>
      'تعذر العثور على الترخيص على الخادم.';

  @override
  String get licenseStatusTitle => 'الخطة والاستحقاق';

  @override
  String get licenseStatusEntitled => 'ميزات Pro مفعلة';

  @override
  String get licenseStatusNotEntitled => 'ميزات Pro غير مفعلة';

  @override
  String get licenseUpdatesCovered => 'التحديثات مشمولة';

  @override
  String get licenseUpdatesExpired => 'التحديثات غير مشمولة';

  @override
  String get licenseActivateOrUpgrade => 'فعّل المفتاح أو قم بالترقية';

  @override
  String get licenseUpgradeToPro => 'الترقية إلى Pro';

  @override
  String get licenseActivateKeyOnly => 'تفعيل مفتاح الترخيص';

  @override
  String get licenseExtendUpdates => 'تمديد التحديثات';

  @override
  String get licenseSubscriptionActive => 'الاشتراك نشط';

  @override
  String get licenseLifetimeActive => 'ترخيص مدى الحياة نشط';

  @override
  String get licenseActivateKeySecondary => 'لديك مفتاح؟ فعّله';

  @override
  String get licenseSummaryHeroTitle => 'ملخص الترخيص';

  @override
  String get licenseSummaryHeroSubtitle =>
      'خطتك الحالية، حالة الاستحقاق، وتغطية التحديثات.';

  @override
  String get licenseDetailsTitle => 'تفاصيل الترخيص';

  @override
  String get licenseDetailsSubtitle => 'معلومات الهوية والتفعيل لهذا الجهاز.';

  @override
  String get licenseActionTitle => 'الإجراء التالي';

  @override
  String get licenseActionSubtitle => 'الخطوة الموصى بها حسب خطتك الحالية.';

  @override
  String get licenseKeyLabel => 'مفتاح الترخيص';

  @override
  String get licenseMemberSince => 'عضو منذ';

  @override
  String get licenseActivatedOnThisDevice => 'تم التفعيل على هذا الجهاز';

  @override
  String get licenseUpdatesUntil => 'التحديثات مشمولة حتى';

  @override
  String get licenseLinkStatus => 'حالة ربط الجهاز';

  @override
  String get licenseSummaryStarter =>
      'فعّل مفتاحًا أو قم بالترقية لفتح صادرات Pro غير المحدودة.';

  @override
  String licenseSummaryTrial(int count) {
    return 'أنت تستخدم الخطة التجريبية مع $count صادرات متبقية.';
  }

  @override
  String get licenseSummarySubscriptionActive =>
      'اشتراكك نشط وجميع ميزات Pro الحالية متاحة.';

  @override
  String get licenseSummaryLifetimeCovered =>
      'أنت تملك Clingfy Pro بشكل دائم وتغطية التحديثات لديك نشطة.';

  @override
  String licenseSummaryLifetimeExpiringSoon(int days) {
    return 'ترخيص مدى الحياة لديك نشط، لكن تغطية التحديثات تنتهي خلال $days يومًا.';
  }

  @override
  String get licenseSummaryLifetimeExpired =>
      'ترخيص مدى الحياة لديك نشط، لكن تغطية التحديثات انتهت.';

  @override
  String get licensePlanTrial => 'تجريبي';

  @override
  String get licensePlanLifetime => 'مدى الحياة';

  @override
  String get licensePlanSubscription => 'اشتراك';

  @override
  String get licensePlanStarter => 'مبتدئ';

  @override
  String get layoutSettings => 'إعدادات المخطط';

  @override
  String get effectsSettings => 'إعدادات التأثيرات';

  @override
  String get exportSettings => 'Export Settings';

  @override
  String get postProcessing => 'المعالجة اللاحقة';

  @override
  String get expandPane => 'توسيع اللوحة';

  @override
  String get collapsePane => 'طي اللوحة';

  @override
  String get showOptions => 'إظهار الخيارات';

  @override
  String get hideOptions => 'إخفاء الخيارات';

  @override
  String get size => 'الحجم';

  @override
  String get padding => 'الهوامش';

  @override
  String get roundedCorners => 'زوايا مستديرة';

  @override
  String get backgroundImage => 'صورة الخلفية';

  @override
  String get moreImages => 'المزيد من الصور';

  @override
  String get pickAnImage => 'اختر صورة';

  @override
  String get backgroundColor => 'لون الخلفية';

  @override
  String get moreColors => 'المزيد من الألوان';

  @override
  String get pickColor => 'اختر لوناً';

  @override
  String get gotIt => 'فهمت';

  @override
  String get showCursor => 'إظهار المؤشر';

  @override
  String get toggleCursorVisibility => 'تبديل ظهور المؤشر';

  @override
  String get cursorSize => 'حجم المؤشر';

  @override
  String get zoomInEffect => 'تأثير التكبير';

  @override
  String get manageZoomEffects => 'إدارة تأثيرات التكبير';

  @override
  String get intensity => 'الشدة';

  @override
  String get layout => 'التخطيط';

  @override
  String get refreshDevicesTooltip => 'تحديث الأجهزة (⌘R)';

  @override
  String get copyLastPathTooltip => 'نسخ المسار الأخير';

  @override
  String get timeline => 'الجدول الزمني';

  @override
  String get closeTimelineTooltip => 'إغلاق الجدول الزمني';

  @override
  String get zoomAddSegment => 'إضافة مقطع تكبير';

  @override
  String get zoomAddOne => 'إضافة واحدة';

  @override
  String get zoomKeepAdding => 'استمرار الإضافة';

  @override
  String get zoomKeepAddingTooltip => 'الاستمرار في إضافة مقاطع التكبير';

  @override
  String get zoomAddOneTooltip => 'إضافة مقطع تكبير واحد';

  @override
  String get zoomAddOneStatus =>
      'أضف تكبيرًا واحدًا • اسحب على مسار التكبير • Esc للإلغاء';

  @override
  String get zoomKeepAddingStatus =>
      'استمر في إضافة التكبيرات • اسحب على مسار التكبير • Esc للخروج';

  @override
  String get zoomMoveStatus => 'نقل التكبير المحدد';

  @override
  String get zoomTrimStartStatus => 'قص بداية التكبير';

  @override
  String get zoomTrimEndStatus => 'قص نهاية التكبير';

  @override
  String get zoomBandSelectStatus => 'تحديد التكبيرات';

  @override
  String get zoomSelectionTools => 'أدوات التحديد';

  @override
  String get zoomDeleteSelectedOne => 'حذف المقطع المحدد';

  @override
  String zoomDeleteSelectedMany(int count) {
    return 'حذف $count مقاطع';
  }

  @override
  String get zoomSelectAfterPlayhead => 'تحديد كل ما بعد رأس التشغيل';

  @override
  String get zoomClearSelection => 'مسح التحديد';

  @override
  String zoomSelectedCount(int count) {
    return '$count محدد';
  }

  @override
  String get zoomSelectAllVisible => 'تحديد كل الظاهر';

  @override
  String get zoomUndoLastAction => 'تراجع عن آخر إجراء';

  @override
  String get zoomSelectionCleared => 'تم مسح التحديد';

  @override
  String get zoomChangeSelectionRange => 'تغيير نطاق التحديد';

  @override
  String stopIn(Object value) {
    return 'توقف خلال $value';
  }

  @override
  String get recording => 'تسجيل';

  @override
  String get classic43 => 'كلاسيك (4:3)';

  @override
  String get classic => 'كلاسيك';

  @override
  String get square11 => 'مربع (1:1)';

  @override
  String get youtube169 => 'يوتيوب (16:9)';

  @override
  String get reel916 => 'ريل (9:16)';

  @override
  String get wide => 'عريض';

  @override
  String get vertical => 'عمودي';

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
  String get recordingInProgress => 'جاري التسجيل الآن';

  @override
  String get recordingPaused => 'التسجيل متوقف مؤقتًا';

  @override
  String get readyToRecord => 'جاهز للتسجيل';

  @override
  String get pause => 'إيقاف مؤقت';

  @override
  String get resume => 'استئناف';

  @override
  String get paused => 'متوقف مؤقتًا';

  @override
  String get stop => 'إيقاف';

  @override
  String get startRecording => 'بدء التسجيل';

  @override
  String get loading => 'جاري التحميل...';

  @override
  String hoursShort(Object value) {
    return '$value س';
  }

  @override
  String minutesShort(Object value) {
    return '$value د';
  }

  @override
  String get off => 'إيقاف';

  @override
  String get whileRecording => 'أثناء التسجيل';

  @override
  String get alwaysOn => 'دائماً';

  @override
  String get general => 'عام';

  @override
  String get settingsWorkspace => 'مساحة العمل';

  @override
  String get settingsWorkspaceDescription => 'المظهر واللغة وسلوك مجلد الحفظ.';

  @override
  String get settingsStorage => 'التخزين';

  @override
  String get settingsStorageDescription =>
      'مساحة التسجيل، والاستخدام الداخلي، وحالة القرص.';

  @override
  String get settingsShortcutsDescription =>
      'خصص اختصارات لوحة المفاتيح وحل التعارضات.';

  @override
  String get settingsLicense => 'الترخيص';

  @override
  String get settingsLicenseDescription =>
      'حالة الخطة والاستحقاق وربط الجهاز وإجراءات الترقية.';

  @override
  String get settingsPermissions => 'الأذونات';

  @override
  String get settingsPermissionsDescription =>
      'حالة الوصول وروابط سريعة إلى إعدادات النظام.';

  @override
  String get settingsDiagnostics => 'التشخيص';

  @override
  String get settingsDiagnosticsDescription =>
      'السجلات وأدوات استكشاف الأخطاء وإصلاحها.';

  @override
  String get settingsAbout => 'حول';

  @override
  String get settingsAboutDescription =>
      'معلومات الإصدار والدعم والروابط القانونية.';

  @override
  String get permissionsTitle => 'الأذونات';

  @override
  String get permissionsHelpText =>
      'راجع الأذونات التي يمكن لـ Clingfy استخدامها وافتح مباشرة صفحة إعدادات النظام المناسبة.';

  @override
  String get permissionsRefreshStatus => 'تحديث الحالة';

  @override
  String get permissionsGranted => 'ممنوح';

  @override
  String get permissionsNotGranted => 'غير ممنوح';

  @override
  String get permissionsRequired => 'مطلوب';

  @override
  String get permissionsOptional => 'اختياري';

  @override
  String get permissionsScreenRecording => 'تسجيل الشاشة';

  @override
  String get permissionsMicrophone => 'الميكروفون';

  @override
  String get permissionsCamera => 'الكاميرا';

  @override
  String get permissionsAccessibility => 'إمكانية الوصول';

  @override
  String get permissionsScreenRecordingHelp =>
      'مطلوب لالتقاط شاشة أو نافذة أو منطقة محددة من الشاشة.';

  @override
  String get permissionsMicrophoneHelp =>
      'يسمح لـ Clingfy بتضمين التعليق الصوتي في التسجيلات.';

  @override
  String get permissionsCameraHelp =>
      'يسمح لـ Clingfy بإظهار طبقة كاميرا الوجه أثناء التسجيل.';

  @override
  String get permissionsAccessibilityHelp =>
      'يُستخدم لإبراز النقرات وتأثيرات المؤشر.';

  @override
  String get permissionsChangedHint =>
      'إذا غيّرت إذنًا في إعدادات النظام، فارجع إلى Clingfy وحدّث هذه الصفحة لرؤية الحالة الحالية.';

  @override
  String get permissionsGrantAccess => 'منح الإذن';

  @override
  String get settingsLinks => 'روابط';

  @override
  String get appTheme => 'مظهر التطبيق';

  @override
  String get appThemeDescription => 'اختر المظهر المفضل لديك';

  @override
  String get systemDefault => 'افتراضي النظام';

  @override
  String get light => 'فاتح';

  @override
  String get dark => 'داكن';

  @override
  String get appLanguage => 'لغة التطبيق';

  @override
  String get appLanguageDescription => 'اختر لغة التطبيق';

  @override
  String get english => 'الإنجليزية';

  @override
  String get arabic => 'العربية';

  @override
  String get romanian => 'الرومانية';

  @override
  String get exportVideo => 'تصدير الفيديو';

  @override
  String get close => 'إغلاق';

  @override
  String get cancel => 'إلغاء';

  @override
  String get enterVideoName => 'أدخل اسماً للفيديو الخاص بك:';

  @override
  String get filename => 'اسم الملف';

  @override
  String get matchSystem => 'مطابقة النظام';

  @override
  String get keyboardShortcuts => 'اختصارات لوحة المفاتيح';

  @override
  String get toggleRecording => 'تبديل التسجيل';

  @override
  String get refreshDevices => 'تحديث الأجهزة';

  @override
  String get toggleActionBar => 'تبديل شريط الإجراءات';

  @override
  String get cycleOverlayMode => 'تبديل وضع الطبقة العلوية';

  @override
  String get pressKeyToCapture => 'اضغط على مجموعة مفاتيح... Esc للإلغاء';

  @override
  String shortcutCollision(Object action) {
    return 'الاختصار مستخدم بالفعل من قبل $action';
  }

  @override
  String get resetShortcuts => 'إعادة تعيين الاختصارات';

  @override
  String get countdown => 'العد التنازلي';

  @override
  String seconds(Object value) {
    return '$value ث';
  }

  @override
  String get recordingFolderBehavior => 'سلوك مجلد التسجيل';

  @override
  String get openFolderAfterStop => 'فتح المجلد بعد إيقاف التسجيل';

  @override
  String get openFolderAfterExport => 'فتح المجلد بعد تصدير الفيديو';

  @override
  String get confirmations => 'تأكيدات';

  @override
  String get warnBeforeClosingUnexportedRecording =>
      'حذّر قبل إغلاق تسجيل غير مُصدَّر';

  @override
  String get warnBeforeClosingUnexportedRecordingDescription =>
      'اعرض تأكيدًا قبل إغلاق التسجيل الحالي إذا لم يتم تصديره بعد.';

  @override
  String get closeUnexportedRecordingTitle => 'هل تريد إغلاق هذا التسجيل؟';

  @override
  String get closeUnexportedRecordingMessage =>
      'لم تقم بتصدير هذا التسجيل بعد. إذا أغلقته الآن، ستفقد الوصول إليه في الجلسة الحالية.';

  @override
  String get doNotShowAgain => 'عدم الإظهار مرة أخرى';

  @override
  String get aboutThisApp => 'عن التطبيق';

  @override
  String get aboutClingfy => 'عن تسجيل هذا';

  @override
  String version(Object value) {
    return 'الإصدار $value';
  }

  @override
  String get aboutDeveloperModeEnabled => 'تم تفعيل وضع المطور';

  @override
  String get aboutDeveloperModeDisabled => 'تم تعطيل وضع المطور';

  @override
  String get aboutBuildMetadata => 'بيانات البناء';

  @override
  String get aboutBuildCommit => 'الالتزام';

  @override
  String get aboutBuildBranch => 'الفرع';

  @override
  String get aboutBuildId => 'معرّف البناء';

  @override
  String get aboutBuildDate => 'تاريخ البناء';

  @override
  String get checkForUpdates => 'التحقق من التحديثات';

  @override
  String get escToCancel => 'Esc للإلغاء';

  @override
  String get menuFile => 'ملف';

  @override
  String get menuView => 'عرض';

  @override
  String get showActionBar => 'إظهار شريط الإجراءات';

  @override
  String get recordingSetupNeedsAttention => 'إعداد التسجيل يحتاج إلى انتباهك';

  @override
  String get storageOverviewTitle => 'سلامة التسجيل';

  @override
  String get storageOverviewDescription =>
      'راقب المساحة الحرة في النظام واستخدام Clingfy لتجنب فشل التسجيلات.';

  @override
  String get storageSystemTitle => 'تخزين النظام';

  @override
  String get storageSystemDescription =>
      'القرص الذي يستخدمه مسار الالتقاط النشط في Clingfy.';

  @override
  String get storageClingfyTitle => 'تخزين Clingfy';

  @override
  String get storageClingfyDescription =>
      'التسجيلات الداخلية والملفات المؤقتة والسجلات.';

  @override
  String get storageActionsTitle => 'الإجراءات';

  @override
  String get storagePathsTitle => 'المسارات';

  @override
  String get storageHealthy => 'جيد';

  @override
  String get storageWarning => 'تحذير';

  @override
  String get storageCritical => 'حرج';

  @override
  String get storageHealthyMessage => 'لدى النظام مساحة كافية للتسجيل العادي.';

  @override
  String get storageWarningMessage =>
      'المساحة الحرة منخفضة. قد تفشل التسجيلات الطويلة.';

  @override
  String get storageCriticalMessage => 'تم حظر التسجيل حتى تتوفر مساحة أكبر.';

  @override
  String get storageRefresh => 'تحديث';

  @override
  String get storageOpenRecordingsFolder => 'افتح مجلد التسجيلات';

  @override
  String get storageOpenTempFolder => 'افتح المجلد المؤقت';

  @override
  String get storageClearCachedRecordings => 'امسح التسجيلات المخزنة مؤقتًا';

  @override
  String get storageClearCachedRecordingsConfirmTitle =>
      'مسح التسجيلات المخزنة مؤقتًا؟';

  @override
  String get storageClearCachedRecordingsConfirmMessage =>
      'سيؤدي هذا إلى إزالة نسخ التسجيلات الداخلية والملفات الجانبية الخاصة بـ Clingfy. لن يتم حذف التسجيلات المصدّرة، ولا يمكن التراجع عن هذا الإجراء.';

  @override
  String get storageClearCachedRecordingsConfirmAction => 'امسح التسجيلات';

  @override
  String storageClearCachedRecordingsSuccess(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تمت إزالة $count تسجيلات مخزنة مؤقتًا.',
      one: 'تمت إزالة تسجيل مخزن مؤقتًا واحد.',
    );
    return '$_temp0';
  }

  @override
  String get storageStatusLabel => 'الحالة';

  @override
  String get storageTotalSpace => 'الإجمالي';

  @override
  String get storageUsedSpace => 'المستخدم';

  @override
  String get storageFreeSpace => 'المتاح';

  @override
  String get storageRecordings => 'التسجيلات';

  @override
  String get storageTemp => 'المؤقت';

  @override
  String get storageLogs => 'السجلات';

  @override
  String get storageClingfyTotal => 'إجمالي استخدام Clingfy';

  @override
  String get storageRecordingsPath => 'مجلد التسجيلات';

  @override
  String get storageTempPath => 'المجلد المؤقت';

  @override
  String get storageLogsPath => 'مجلد السجلات';

  @override
  String get storageActionFailed => 'فشل إجراء التخزين.';

  @override
  String storageFreeNow(String value) {
    return 'المتاح الآن: $value';
  }

  @override
  String get missingRequiredPermission => 'هناك إذن مطلوب مفقود';

  @override
  String get missingOptionalPermissionsForRequestedFeatures =>
      'هناك أذونات اختيارية مفقودة للميزات المطلوبة';

  @override
  String get grantPermissions => 'منح الأذونات';

  @override
  String get recordWithoutMissingFeatures => 'سجّل بدون الميزات المفقودة';

  @override
  String get storagePreflightTitle => 'التخزين يحتاج إلى انتباهك';

  @override
  String get storagePreflightCriticalIntro =>
      'اكتشف Clingfy مساحة حرة منخفضة جدًا على قرص التسجيل النشط. تم حظر التسجيل لتجنب فشل الالتقاط.';

  @override
  String get storagePreflightWarningIntro =>
      'المساحة الحرة أصبحت منخفضة. قد تفشل التسجيلات الطويلة قبل أن تنتهي.';

  @override
  String get storageAvailableNow => 'المتاح الآن';

  @override
  String get storageRecordingBlockedBelow => 'يتم حظر التسجيل تحت';

  @override
  String get storageRecommendedFreeSpace => 'المساحة الحرة الموصى بها';

  @override
  String get openStorageSettings => 'افتح إعدادات التخزين';

  @override
  String get recordAnyway => 'سجل على أي حال';

  @override
  String get storageBypassAndRecord => 'تجاوز وابدأ التسجيل';

  @override
  String get cameraForFaceCam => 'الكاميرا من أجل Face Cam';

  @override
  String get microphoneForVoice => 'الميكروفون من أجل الصوت';

  @override
  String get accessibilityForCursorHighlight =>
      'إمكانية الوصول من أجل تمييز المؤشر';

  @override
  String get menuRecord => 'تسجيل';

  @override
  String get unknown => 'غير معروف';

  @override
  String get none => 'لا يوجد';

  @override
  String get appDescription => 'مسجل شاشة بسيط وقوي لنظام macOS.';

  @override
  String get visitWebsite => 'زيارة الموقع';

  @override
  String get contactSupport => 'الاتصال بالدعم';

  @override
  String get privacyPolicy => 'سياسة الخصوصية';

  @override
  String get termsOfService => 'شروط الخدمة';

  @override
  String get locationLabel => 'الموقع:';

  @override
  String get changeButtonLabel => 'تغيير...';

  @override
  String get cancelExport => 'إلغاء التصدير';

  @override
  String get cancelExportConfirm =>
      'هل أنت متأكد أنك تريد إيقاف عملية التصدير؟';

  @override
  String get keepExporting => 'متابعة التصدير';

  @override
  String get stopExport => 'إيقاف التصدير';

  @override
  String get runInBackground => 'تشغيل في الخلفية';

  @override
  String get hideProgress => 'إخفاء التقدم';

  @override
  String get showProgress => 'إظهار التقدم';

  @override
  String get cancelingExport => 'جارٍ إلغاء التصدير...';

  @override
  String get exportAlreadyInProgress => 'يوجد تصدير قيد التنفيذ بالفعل.';

  @override
  String get errAlreadyRecording => 'هناك تسجيل قيد العمل بالفعل.';

  @override
  String get errNoWindowSelected => 'يرجى اختيار نافذة للتسجيل.';

  @override
  String get errNoAreaSelected => 'يرجى اختيار منطقة للتسجيل أولاً.';

  @override
  String get errTargetError => 'تعذر تحديد هدف التسجيل.';

  @override
  String get errNotRecording => 'لا يوجد تسجيل نشط لإيقافه.';

  @override
  String get errInvalidRecordingState =>
      'هذا الإجراء غير متاح في حالة التسجيل الحالية.';

  @override
  String get errPauseResumeUnsupported =>
      'الإيقاف المؤقت والاستئناف غير مدعومين في إعداد التسجيل الحالي.';

  @override
  String get errUnknownAudioDevice => 'جهاز الصوت المختار لم يعد متاحاً.';

  @override
  String get errBadQuality => 'جودة تسجيل غير صالحة.';

  @override
  String get errScreenRecordingPermission =>
      'يرجى تفعيل تسجيل الشاشة في إعدادات النظام > الخصوصية والأمن > تسجيل الشاشة، ثم المحاولة مرة أخرى.';

  @override
  String get errWindowUnavailable =>
      'النافذة المختارة لم تعد متاحة. قم بتحديث القائمة واختيارها مرة أخرى.';

  @override
  String errRecordingError(Object error) {
    return 'حدث خطأ أثناء التسجيل: $error';
  }

  @override
  String errOutputUrlError(Object error) {
    return 'تعذر إنشاء ملف المخرجات: $error';
  }

  @override
  String get errAccessibilityPermissionRequired =>
      'يرجى تفعيل إذن الوصول (Accessibility) لتمييز المؤشر من إعدادات النظام، ثم أعد تشغيل التطبيق.';

  @override
  String get errMicrophonePermissionRequired =>
      'يرجى تفعيل الوصول إلى الميكروفون في إعدادات النظام > الخصوصية والأمن > الميكروفون، ثم حاول مرة أخرى.';

  @override
  String errExportError(Object error) {
    return 'حدث خطأ أثناء التصدير: $error';
  }

  @override
  String get errCameraPermissionDenied =>
      'يرجى تفعيل الكاميرا في إعدادات النظام > الخصوصية والأمن > الكاميرا.';

  @override
  String get shape => 'الشكل';

  @override
  String get squircle => 'سكويركل';

  @override
  String get circle => 'دائرة';

  @override
  String get roundedRect => 'مستطيل مستدير';

  @override
  String get square => 'مربع';

  @override
  String get hexagon => 'سداسي';

  @override
  String get star => 'نجمة';

  @override
  String cornerRoundness(Object value) {
    return 'استدارة الزاوية: $value%';
  }

  @override
  String sizePx(Object value) {
    return 'الحجم: $value بكسل';
  }

  @override
  String opacityPercent(Object value) {
    return 'الشفافية: $value%';
  }

  @override
  String get mirrorSelfView => 'مرآة العرض';

  @override
  String get chromaKey => 'كروما (شاشة خضراء)';

  @override
  String keyTolerance(Object value) {
    return 'تسامح المفتاح: $value%';
  }

  @override
  String get chromaKeyColor => 'لون الكروما';

  @override
  String get pickChromaKeyColor => 'اختر لون الكروما';

  @override
  String get targetColorToRemove => 'اللون المستهدف للاستبعاد';

  @override
  String get position => 'الموقع';

  @override
  String get customPosition => 'موضع مخصص';

  @override
  String get customPositionHint => 'تم السحب يدويًا. اختر زاوية للعودة.';

  @override
  String get shadow => 'الظل';

  @override
  String get border => 'الحدود';

  @override
  String get pickBorderColor => 'اختر لون الحدود';

  @override
  String borderWidth(Object value) {
    return 'عرض الحدود: $value بكسل';
  }

  @override
  String get diagnosticsTitle => 'التشخيص';

  @override
  String get diagnosticsHelpText =>
      'في حال حدوث خطأ ما، افتح مجلد السجلات وأرسل ملف سجل اليوم للدعم.';

  @override
  String get openLogsFolder => 'افتتاح مجلد السجلات';

  @override
  String get revealTodayLog => 'إظهار ملف سجل اليوم';

  @override
  String get copyLogPath => 'نسخ المسار';

  @override
  String get errVideoFileMissing => 'تم نقل أو حذف ملف التسجيل.';

  @override
  String get errCursorFileMissing =>
      'بيانات المؤشر مفقودة. تم تعطيل تأثيرات المؤشر.';

  @override
  String get errExportInputMissing =>
      'لم يتم العثور على ملف التسجيل. ربما تم نقله أو حذفه.';

  @override
  String get errAssetInvalid => 'فشل في تحضير معاينة الفيديو.';

  @override
  String get applyEffects => 'تطبيق التأثيرات';

  @override
  String get recordingSaved => 'تم حفظ التسجيل:';

  @override
  String get exportSuccess => 'تم التصدير بنجاح:';

  @override
  String get open => 'فتح';

  @override
  String get cursorDataMissing => 'بيانات المؤشر مفقودة';

  @override
  String get voiceBoost => 'تعزيز الصوت';

  @override
  String get audioGain => 'مكسب الصوت';

  @override
  String get volume => 'مستوى الصوت';

  @override
  String get micInputLevel => 'مستوى دخل الميكروفون';

  @override
  String get micInputIndicatorDisabledTooltip =>
      'اختر ميكروفونًا لمعاينة مستوى الإدخال.';

  @override
  String micInputIndicatorLiveTooltip(String dbfs) {
    return 'مستوى إدخال الميكروفون: $dbfs dBFS';
  }

  @override
  String get micInputIndicatorLowTooltip =>
      'مستوى إدخال الميكروفون منخفض جدًا. ارفع مستوى الإدخال أو اقترب من الميكروفون.';

  @override
  String get noMicAudioFound => 'لم يتم العثور على مسار صوتي للميكروفون';

  @override
  String get autoNormalizeOnExport => 'تطبيع تلقائي عند التصدير';

  @override
  String get targetLoudness => 'مستوى الصوت المستهدف';

  @override
  String get selectCameraHint => 'اختر كاميرا لتهيئة إعدادات الطبقة العلوية';

  @override
  String get closePreview => 'إغلاق المعاينة';

  @override
  String get preparingPreview => 'جاري تحضير المعاينة...';

  @override
  String get menuStartRecording => 'بدء التسجيل';

  @override
  String get menuStopRecording => 'إيقاف التسجيل';

  @override
  String get menuOpenApp => 'فتح Clingfy';

  @override
  String get menuQuit => 'إنهاء Clingfy';

  @override
  String get captureSettings => 'إعدادات الالتقاط';

  @override
  String get captureSettingsDescription => 'تكوين سلوك التقاط الشاشة.';

  @override
  String get excludeRecorderAppFromCapture =>
      'استبعاد تطبيق التسجيل من الالتقاط';

  @override
  String get excludeRecorderAppFromCaptureDescription =>
      'عند التفعيل، يتم إخفاء نافذة التسجيل من التسجيلات. قم بالتعطيل لتضمينها (مفيد لدروس حول هذا التطبيق).';

  @override
  String get ok => 'موافق';

  @override
  String get copy => 'نسخ';

  @override
  String get copiedToClipboard => 'تم النسخ إلى الحافظة';

  @override
  String get loadingYourSettings => 'جارٍ تحميل إعداداتك...';

  @override
  String get renderingErrorFallbackMessage =>
      'حدث خطأ في العرض.\nتحقق من السجلات لمزيد من التفاصيل.';

  @override
  String get debugResetPreferencesTitle => 'إعادة تعيين التفضيلات؟';

  @override
  String get debugResetPreferencesMessage =>
      'سيؤدي هذا إلى مسح جميع الإعدادات المحفوظة.';

  @override
  String get debugResetPreferencesConfirm => 'إعادة التعيين';

  @override
  String get debugResetPreferencesSemanticLabel =>
      'إعادة تعيين التفضيلات (تصحيح)';

  @override
  String get diagnosticsLogFileNotFound =>
      'لم يتم العثور على ملف السجل. حاول إعادة إنتاج المشكلة أولاً.';

  @override
  String get diagnosticsLogFileUnavailable => 'مسار ملف السجل غير متاح الآن.';

  @override
  String get diagnosticsActionFailed => 'تعذر إكمال هذا الإجراء.';

  @override
  String get diagnosticsLogRevealed => 'تم إظهار ملف سجل اليوم.';

  @override
  String get recordingSystemAudio => 'صوت النظام';

  @override
  String get recordingExcludeMicFromSystemAudio =>
      'استبعاد الميكروفون الخاص بي من صوت النظام';

  @override
  String get restartApp => 'أعد تشغيل التطبيق';

  @override
  String get permissionsOnboardingWelcomeRail => 'مرحبًا';

  @override
  String get permissionsOnboardingMicCameraRail => 'الميكروفون + الكاميرا';

  @override
  String permissionsOnboardingStepLabel(int current) {
    return 'الخطوة $current من 4';
  }

  @override
  String get permissionsOnboardingWelcomeTitle => 'مرحبًا بك في Clingfy';

  @override
  String get permissionsOnboardingWelcomeSubtitle =>
      'إعداد سريع وستكون جاهزًا للتسجيل خلال دقائق.';

  @override
  String get permissionsOnboardingTrustLocalFirst =>
      'محلي أولاً: تبقى تسجيلاتك على جهاز Mac الخاص بك.';

  @override
  String get permissionsOnboardingTrustPermissionControl =>
      'يمكنك التحكم في الأذونات في أي وقت من إعدادات النظام.';

  @override
  String get permissionsOnboardingFeatureExportsTitle => 'تصدير واضح بدقة 4K+';

  @override
  String get permissionsOnboardingFeatureExportsSubtitle =>
      'إعدادات مسبقة ليوتيوب وReels والمزيد.';

  @override
  String get permissionsOnboardingFeatureZoomTitle =>
      'تتبّع التكبير + تأثيرات المؤشر';

  @override
  String get permissionsOnboardingFeatureZoomSubtitle =>
      'يساعد المشاهدين على متابعة ما يهم.';

  @override
  String get permissionsOnboardingScreenTitle => 'تسجيل الشاشة (مطلوب)';

  @override
  String get permissionsOnboardingScreenSubtitle =>
      'يتطلب macOS هذا قبل بدء أي تسجيل. يستغرق نحو 15 ثانية.';

  @override
  String get permissionsOnboardingWhyAreYouAsking => 'لماذا تطلبون هذا؟';

  @override
  String get permissionsOnboardingWhyIsThisNeeded => 'لماذا هذا مطلوب؟';

  @override
  String get permissionsOnboardingWhyScreenTitle => 'لماذا إذن تسجيل الشاشة؟';

  @override
  String get permissionsOnboardingWhyScreenSubtitle =>
      'هذا الإذن مطلوب من macOS لالتقاط وحدات البكسل من شاشتك.';

  @override
  String get permissionsOnboardingWhyScreenBullet1 =>
      'مطلوب لتسجيل الشاشة الكاملة والتقاط النوافذ وتحديد منطقة مخصصة.';

  @override
  String get permissionsOnboardingWhyScreenBullet2 =>
      'يسجل Clingfy محليًا؛ أما التصدير فهو إجراء تبدأه أنت.';

  @override
  String get permissionsOnboardingWhyScreenBullet3 =>
      'يمكنك تعطيله في أي وقت من إعدادات النظام.';

  @override
  String get permissionsOnboardingWhyScreenFooter =>
      'إذا عرض macOS مفتاح تبديل لـ Clingfy، فتأكد من أنه مفعّل.';

  @override
  String get permissionsOnboardingScreenTrustLine1 =>
      'محلي أولاً: تبقى التسجيلات على جهاز Mac الخاص بك.';

  @override
  String get permissionsOnboardingScreenTrustLine2 =>
      'أنت المتحكم دائمًا — يمكنك تغيير ذلك في أي وقت.';

  @override
  String get permissionsOnboardingRestartHint =>
      'إذا عرض macOS مفتاح تبديل، فتأكد من أنه مفعّل. قد تحتاج إلى إعادة تشغيل Clingfy.';

  @override
  String get permissionsOnboardingVoiceCameraTitle =>
      'الصوت وواجهة الكاميرا (اختياري)';

  @override
  String get permissionsOnboardingVoiceCameraSubtitle =>
      'يُنصح به للدروس التعليمية، لكن يمكنك تخطيه وتفعيله لاحقًا.';

  @override
  String get permissionsOnboardingMicrophoneDescription =>
      'للسرد الصوتي وتعزيز الصوت.';

  @override
  String get permissionsOnboardingEnableMic => 'تفعيل الميكروفون';

  @override
  String get permissionsOnboardingWhyMicrophoneTitle => 'لماذا الميكروفون؟';

  @override
  String get permissionsOnboardingWhyMicrophoneSubtitle =>
      'حتى تتضمن تسجيلاتك تعليقك الصوتي.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet1 =>
      'يُستخدم فقط عند تفعيل تسجيل الميكروفون.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet2 =>
      'يمكنك اختيار جهاز الإدخال داخل التطبيق.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet3 =>
      'يمكنك سحب الإذن في أي وقت.';

  @override
  String get permissionsOnboardingCameraDescription =>
      'اعرض وجهك في فقاعة قابلة للتخصيص.';

  @override
  String get permissionsOnboardingEnableCamera => 'تفعيل الكاميرا';

  @override
  String get permissionsOnboardingWhyCameraTitle => 'لماذا الكاميرا؟';

  @override
  String get permissionsOnboardingWhyCameraSubtitle =>
      'لإضافات face-cam (اختياري).';

  @override
  String get permissionsOnboardingWhyCameraBullet1 =>
      'تُستخدم فقط عند تفعيل فقاعة الكاميرا.';

  @override
  String get permissionsOnboardingWhyCameraBullet2 =>
      'يمكنك إيقافها في أي وقت أثناء التسجيل.';

  @override
  String get permissionsOnboardingWhyCameraBullet3 =>
      'يمكنك سحب الإذن في أي وقت.';

  @override
  String get permissionsOnboardingAudioTrustLine1 =>
      'خطوة اختيارية — يمكنك التسجيل بدون ميكروفون أو كاميرا.';

  @override
  String get permissionsOnboardingAudioTrustLine2 =>
      'يمكنك تفعيلهما لاحقًا في أي وقت من إعدادات التطبيق.';

  @override
  String get permissionsOnboardingCursorTitle => 'سحر المؤشر (اختياري)';

  @override
  String get permissionsOnboardingCursorSubtitle =>
      'فعّل تمييز النقرات وحركة المؤشر الأكثر سلاسة للمشاهدين.';

  @override
  String get permissionsOnboardingAccessibilityDescription =>
      'يُستخدم لاكتشاف نقرات الماوس من أجل تأثيرات المؤشر.';

  @override
  String get permissionsOnboardingCheck => 'تحقق';

  @override
  String get permissionsOnboardingWhyAccessibilityTitle =>
      'لماذا تسهيلات الاستخدام؟';

  @override
  String get permissionsOnboardingWhyAccessibilitySubtitle =>
      'يجمع macOS الوصول إلى أحداث الماوس ضمن أذونات تسهيلات الاستخدام.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet1 =>
      'يُستخدم لتمييز النقرات وتأثيرات سحر المؤشر.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet2 =>
      'يُنصح به للدروس والعروض، لكنه غير مطلوب للتسجيل.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet3 =>
      'يمكنك سحبه في أي وقت من إعدادات النظام.';

  @override
  String get permissionsOnboardingCursorTrustLine1 =>
      'خطوة اختيارية — ستعمل تسجيلاتك من دونه.';

  @override
  String get permissionsOnboardingCursorTrustLine2 =>
      'يمكنك تفعيل سحر المؤشر لاحقًا متى شئت.';

  @override
  String get permissionsOnboardingSkipForNow => 'تخطَّ الآن';

  @override
  String get permissionsOnboardingBack => 'رجوع';

  @override
  String get permissionsOnboardingNext => 'متابعة';

  @override
  String get permissionsOnboardingLetsRecord => 'لنبدأ التسجيل! 🚀';
}
