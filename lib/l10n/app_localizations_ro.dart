// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Romanian Moldavian Moldovan (`ro`).
class AppLocalizationsRo extends AppLocalizations {
  AppLocalizationsRo([String locale = 'ro']) : super(locale);

  @override
  String get appTitle => 'Clingfy — Înregistrator Ecran';

  @override
  String get record => 'Înregistrare';

  @override
  String get output => 'Rezultat';

  @override
  String get settings => 'Setări';

  @override
  String get tabScreenAudio => 'Ecran și audio';

  @override
  String get tabFaceCam => 'Face Cam';

  @override
  String get screenTarget => 'Țintă ecran';

  @override
  String get recordTarget => 'Țintă înregistrare';

  @override
  String get captureSource => 'Sursă captură';

  @override
  String get chosenScreen => 'Ecran ales';

  @override
  String get appWindowScreen => 'Ecranul ferestrei aplicației';

  @override
  String get specificAppWindow => 'Fereastră aplicație specifică';

  @override
  String get screenUnderMouse => 'Ecran sub mouse (la început)';

  @override
  String get followMouse => 'Urmărește mouse-ul (divide fișierele)';

  @override
  String get followMouseNote =>
      'Notă: cu codificatorul curent, înregistrarea se va diviza când mouse-ul se mută pe un alt ecran.';

  @override
  String get display => 'Ecran';

  @override
  String get refreshDisplays => 'Reîmprospătare ecrane (⌘R)';

  @override
  String get screenToRecord => 'Ecran de înregistrat';

  @override
  String get mainDisplay => 'Ecran principal';

  @override
  String get appWindow => 'Fereastră aplicație';

  @override
  String get refreshWindows => 'Reîmprospătare ferestre';

  @override
  String get windowToRecord => 'Fereastră de înregistrat';

  @override
  String get selectAppWindow => 'Selectează o fereastră';

  @override
  String get refreshWindowHint =>
      'Reîmprospătează dacă nu vezi fereastra, apoi selecteaz-o mai sus.';

  @override
  String get areaRecording => 'Înregistrare zonă';

  @override
  String get pickArea => 'Alege zona...';

  @override
  String get changeArea => 'Schimbă zona';

  @override
  String get revealArea => 'Arată';

  @override
  String get clearArea => 'Șterge imaginea';

  @override
  String get areaRecordingHelper =>
      'Înregistrează o zonă rectangulară personalizată a ecranului.';

  @override
  String get noAreaSelected => 'Nicio zonă selectată';

  @override
  String selectedAreaAt(
    Object height,
    Object id,
    Object width,
    Object x,
    Object y,
  ) {
    return 'Ecran $id: ${width}x$height la ($x, $y)';
  }

  @override
  String get audio => 'Audio';

  @override
  String get pointer => 'Pointer';

  @override
  String get refreshAudio => 'Reîmprospătare dispozitive audio (⌘R)';

  @override
  String get inputDevice => 'Dispozitiv intrare';

  @override
  String get noAudio => 'Fără audio';

  @override
  String get camera => 'Cameră';

  @override
  String get refreshCameras => 'Reîmprospătare camere (⌘R)';

  @override
  String get cameraDevice => 'Dispozitiv cameră';

  @override
  String get recordingQuality => 'Calitate înregistrare';

  @override
  String get quality => 'Calitate';

  @override
  String get resolution => 'Rezoluție';

  @override
  String get frameRate => 'Rată cadre';

  @override
  String fps(Object value) {
    return '$value FPS';
  }

  @override
  String get saveLocation => 'Locație salvare';

  @override
  String get format => 'Format';

  @override
  String get codec => 'Codec';

  @override
  String get bitrate => 'Rată de biți';

  @override
  String get hevc => 'HEVC (H.265)';

  @override
  String get h264 => 'H.264';

  @override
  String get auto => 'Auto';

  @override
  String get low => 'Scăzută';

  @override
  String get medium => 'Medie';

  @override
  String get high => 'Ridicată';

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
  String get revealInFinder => 'Arată în Finder';

  @override
  String get resetToDefault => 'Resetare la implicit';

  @override
  String get openFolder => 'Deschide folderul';

  @override
  String get recordingHighlight => 'Stralucire la înregistrare';

  @override
  String get recordingGlowStrength => 'Intensitate strălucire';

  @override
  String recordingGlowStrengthPercent(Object value) {
    return 'Intensitate strălucire: $value%';
  }

  @override
  String get chooseSaveFolder => 'Alege folder salvare…';

  @override
  String get defaultSaveFolder => 'Implicit: ~/Movies/Clingfy';

  @override
  String get duration => 'Durată';

  @override
  String get startAndStop => 'Pornire și oprire';

  @override
  String get autoStopAfter => 'Oprire automată după';

  @override
  String get preset => 'Presetare';

  @override
  String get customMinutes => 'Personalizat (minute)';

  @override
  String get forceLetterbox => 'Forțează 16:9 (letterbox)';

  @override
  String get forceLetterboxSubtitle =>
      'Centrează ecranul într-un cadru 16:9 (ex. 1080p) cu margini negre.';

  @override
  String get forceLetterboxHint =>
      'Corectează afișarea pe YouTube când ecranul este ultra-wide sau nu este 16:9.';

  @override
  String get appSettings => 'Setări Aplicație';

  @override
  String get appSettingsDescription =>
      'Gestionează preferințele de workspace, scurtăturile, statusul licenței, diagnosticele și detaliile aplicației.';

  @override
  String get openAppSettings => 'Deschide Setări Aplicație';

  @override
  String get expandNavigationRail => 'Extinde bara de navigare';

  @override
  String get compactNavigationRail => 'Compactează bara de navigare';

  @override
  String get overlayFaceCam => 'Suprapunere (Face-cam)';

  @override
  String get overlayFaceCamVisibility => 'Vizibilitate Face-cam';

  @override
  String get visibilityAndPlacement => 'Vizibilitate și poziționare';

  @override
  String get appearance => 'Aspect';

  @override
  String get style => 'Stil';

  @override
  String get effects => 'Efecte';

  @override
  String get visibility => 'Vizibilitate';

  @override
  String get overlayHint => 'Suprapunerea va apărea când începe înregistrarea.';

  @override
  String get recordingIndicator => 'Indicator înregistrare';

  @override
  String get showIndicator => 'Arată indicator înregistrare';

  @override
  String get pinToTopRight => 'Fixează în dreapta-sus';

  @override
  String get indicatorHint =>
      'Un punct mic “REC” apare în timpul înregistrării. Fixat, rămâne în dreapta-sus; altfel îl poți trage.';

  @override
  String get cursorHighlight => 'Evidențiere cursor';

  @override
  String get cursorHighlightVisibility =>
      'Vizibilitatea evidențierii cursorului';

  @override
  String get cursorHint =>
      'Evidențierea cursorului este activă doar în timpul înregistrării.';

  @override
  String get appTitleFull => 'Clingfy — Înregistrator Ecran';

  @override
  String get recordingPathCopied => 'Calea înregistrării a fost copiată';

  @override
  String get grantAccessibilityPermission =>
      'Acordați permisiunea de Accesibilitate pentru a evidenția cursorul.';

  @override
  String get openSettings => 'Deschide Setări';

  @override
  String get export => 'Exportă';

  @override
  String get exporting => 'Se exportă...';

  @override
  String get paywallTitle => 'Deblochează exporturile Pro';

  @override
  String get paywallSubtitle =>
      'Upgradează planul sau activează o cheie de licență pentru a continua exportul.';

  @override
  String paywallTrialRemaining(int count) {
    return 'Exporturi trial rămase: $count';
  }

  @override
  String get paywallTrialTier =>
      'Plan trial: exporturi limitate pentru testarea funcțiilor';

  @override
  String get paywallLifetimeTier =>
      'Plan pe viață: plată unică cu acoperire de actualizări';

  @override
  String get paywallSubscriptionTier =>
      'Plan abonament: acces continuu și actualizări';

  @override
  String get paywallAlreadyHaveKey => 'Ai deja o cheie?';

  @override
  String get paywallLicenseKeyHint => 'Introdu cheia de licență';

  @override
  String get paywallLicenseKeyRequired =>
      'Te rugăm să introduci o cheie de licență.';

  @override
  String get paywallActivateKey => 'Activează cheia';

  @override
  String get paywallActivationFailed => 'Activarea licenței a eșuat.';

  @override
  String get paywallExportBlocked =>
      'Exportul este blocat. Upgradează sau activează o cheie pentru a continua.';

  @override
  String get paywallConsumeFailed =>
      'Export reușit, dar sincronizarea creditului trial a eșuat. Verifică conexiunea.';

  @override
  String get paywallSubtitleStarter =>
      'Obții exporturi nelimitate, fără watermark și toate funcțiile Pro.';

  @override
  String paywallSubtitleTrial(int count) {
    return 'Ai $count exporturi gratuite rămase. Fă upgrade pentru a elimina limitele.';
  }

  @override
  String get paywallCardMonthlyTitle => 'Pro Lunar';

  @override
  String get paywallCardMonthlyPrice => '\$9.99';

  @override
  String get paywallCardMonthlyPeriod => '/ lună';

  @override
  String get paywallCardMonthlyDescription =>
      'Primești mereu cele mai noi funcții.';

  @override
  String get paywallCardMonthlyFeature1 => 'Exporturi nelimitate';

  @override
  String get paywallCardMonthlyFeature2 => 'Fără watermark';

  @override
  String get paywallCardMonthlyFeature3 => 'Suport prioritar';

  @override
  String get paywallCardMonthlyCta => 'Abonează-te';

  @override
  String get paywallCardLifetimeTitle => 'Pro pe Viață';

  @override
  String get paywallCardLifetimePrice => '\$59.99';

  @override
  String get paywallCardLifetimePeriod => 'o singură dată';

  @override
  String get paywallCardLifetimeDescription =>
      'Deții Clingfy pentru totdeauna + 1 an de actualizări.';

  @override
  String get paywallCardLifetimeFeature1 => 'Deținere permanentă';

  @override
  String get paywallCardLifetimeFeature2 => 'Include 1 an de actualizări';

  @override
  String get paywallCardLifetimeFeature3 => 'Exporturi nelimitate';

  @override
  String get paywallCardLifetimeFeature4 => 'Fără watermark';

  @override
  String get paywallCardLifetimeCta => 'Cumpără pe Viață';

  @override
  String get paywallCardExtensionTitle => 'Extensie Actualizări';

  @override
  String get paywallCardExtensionPrice => '\$19.99';

  @override
  String get paywallCardExtensionPeriod => 'o singură dată';

  @override
  String get paywallCardExtensionDescription =>
      'Extinde eligibilitatea pentru actualizări cu +12 luni.';

  @override
  String get paywallCardExtensionFeature1 => 'Adaugă +12 luni de actualizări';

  @override
  String get paywallCardExtensionFeature2 => 'Păstrezi deținerea pe viață';

  @override
  String get paywallCardExtensionFeature3 => 'Funcționează cu cheia existentă';

  @override
  String get paywallCardExtensionCta => 'Extinde Actualizările';

  @override
  String get paywallRecommendedBadge => 'RECOMANDAT';

  @override
  String get paywallActivationSuccess => 'Pro a fost deblocat cu succes!';

  @override
  String get paywallPricingOpenFailed =>
      'Nu s-a putut deschide pagina de prețuri.';

  @override
  String get licenseDevicesTitle => 'Licență și Dispozitive';

  @override
  String get licenseDevicesSubtitle =>
      'Gestionează legătura de licență a acestui Mac pentru transfer între dispozitive.';

  @override
  String get licensePlanLabel => 'Plan';

  @override
  String get licenseDeviceLinked =>
      'Acest dispozitiv este asociat cheii tale de licență.';

  @override
  String get licenseDeviceNotLinked =>
      'Nicio licență activă nu este asociată acestui dispozitiv.';

  @override
  String get licenseDeactivateButton => 'Dezactivează acest dispozitiv';

  @override
  String get licenseDeactivateConfirmTitle => 'Dezactivezi acest dispozitiv?';

  @override
  String get licenseDeactivateConfirmBody =>
      'Acest lucru va deconecta Mac-ul curent de la cheia ta de licență de pe server.';

  @override
  String get licenseDeactivateConfirmAction => 'Dezactivează';

  @override
  String get licenseDeactivateSuccess => 'Dispozitiv dezactivat cu succes.';

  @override
  String get licenseDeactivateFailed =>
      'Nu s-a putut dezactiva acest dispozitiv acum.';

  @override
  String get licenseDeactivateUnavailable =>
      'Licența nu a fost găsită pe server.';

  @override
  String get licenseStatusTitle => 'Plan și Eligibilitate';

  @override
  String get licenseStatusEntitled => 'Funcțiile Pro sunt deblocate';

  @override
  String get licenseStatusNotEntitled => 'Funcțiile Pro sunt blocate';

  @override
  String get licenseUpdatesCovered => 'Actualizări incluse';

  @override
  String get licenseUpdatesExpired => 'Actualizări neacoperite';

  @override
  String get licenseActivateOrUpgrade => 'Activează cheia sau fă upgrade';

  @override
  String get licenseUpgradeToPro => 'Upgrade la Pro';

  @override
  String get licenseActivateKeyOnly => 'Activează cheia de licență';

  @override
  String get licenseExtendUpdates => 'Extinde actualizările';

  @override
  String get licenseSubscriptionActive => 'Abonament activ';

  @override
  String get licenseLifetimeActive => 'Licență pe viață activă';

  @override
  String get licenseActivateKeySecondary => 'Ai o cheie? Activeaz-o';

  @override
  String get licenseSummaryHeroTitle => 'Rezumat licență';

  @override
  String get licenseSummaryHeroSubtitle =>
      'Planul curent, eligibilitatea și acoperirea actualizărilor.';

  @override
  String get licenseDetailsTitle => 'Detalii licență';

  @override
  String get licenseDetailsSubtitle =>
      'Informații de identitate și activare pentru acest dispozitiv.';

  @override
  String get licenseActionTitle => 'Următoarea acțiune';

  @override
  String get licenseActionSubtitle =>
      'Pasul recomandat în funcție de planul curent.';

  @override
  String get licenseKeyLabel => 'Cheie de licență';

  @override
  String get licenseMemberSince => 'Membru din';

  @override
  String get licenseActivatedOnThisDevice => 'Activat pe acest dispozitiv';

  @override
  String get licenseUpdatesUntil => 'Actualizări incluse până la';

  @override
  String get licenseLinkStatus => 'Legare dispozitiv';

  @override
  String get licenseSummaryStarter =>
      'Activează o cheie sau fă upgrade pentru exporturi Pro nelimitate.';

  @override
  String licenseSummaryTrial(int count) {
    return 'Folosești Trial cu $count exporturi rămase.';
  }

  @override
  String get licenseSummarySubscriptionActive =>
      'Abonamentul este activ și toate funcțiile Pro curente sunt deblocate.';

  @override
  String get licenseSummaryLifetimeCovered =>
      'Deții Clingfy Pro permanent, iar acoperirea actualizărilor este activă.';

  @override
  String licenseSummaryLifetimeExpiringSoon(int days) {
    return 'Licența ta pe viață este activă, dar acoperirea actualizărilor expiră în $days zile.';
  }

  @override
  String get licenseSummaryLifetimeExpired =>
      'Licența ta pe viață este activă, dar acoperirea actualizărilor a expirat.';

  @override
  String get licensePlanTrial => 'Trial';

  @override
  String get licensePlanLifetime => 'Pe viață';

  @override
  String get licensePlanSubscription => 'Abonament';

  @override
  String get licensePlanStarter => 'Starter';

  @override
  String get layoutSettings => 'Setări Layout';

  @override
  String get effectsSettings => 'Setări Efecte';

  @override
  String get exportSettings => 'Setări export';

  @override
  String get canvas => 'Canvas';

  @override
  String get canvasSettings => 'Setări Canvas';

  @override
  String get cameraSettings => 'Setări Cameră';

  @override
  String get postProcessing => 'Post-procesare';

  @override
  String get expandPane => 'Extinde panoul';

  @override
  String get collapsePane => 'Restrânge panoul';

  @override
  String get showOptions => 'Arată opțiunile';

  @override
  String get hideOptions => 'Ascunde opțiunile';

  @override
  String get canvasFormat => 'Format Canvas';

  @override
  String get framing => 'Încadrare';

  @override
  String get background => 'Fundal';

  @override
  String get size => 'Dimensiune';

  @override
  String get padding => 'Padding';

  @override
  String get roundedCorners => 'Colțuri rotunjite';

  @override
  String get backgroundImage => 'Imagine fundal';

  @override
  String get moreImages => 'Mai multe imagini';

  @override
  String get pickAnImage => 'Alege o imagine';

  @override
  String get backgroundColor => 'Culoare fundal';

  @override
  String get moreColors => 'Mai multe culori';

  @override
  String get pickColor => 'Alege o culoare';

  @override
  String get gotIt => 'Am înțeles';

  @override
  String get increase => 'Mărește';

  @override
  String get decrease => 'Micșorează';

  @override
  String get showCursor => 'Arată Cursor';

  @override
  String get toggleCursorVisibility => 'Comutare vizibilitate cursor';

  @override
  String get cursorSize => 'Dimensiune Cursor';

  @override
  String get cursor => 'Cursor';

  @override
  String get zoomInEffect => 'Efect Zoom';

  @override
  String get manageZoomEffects => 'Gestionează efecte zoom';

  @override
  String get zoom => 'Zoom';

  @override
  String get intensity => 'Intensitate';

  @override
  String get layout => 'Aspect';

  @override
  String get loudness => 'Volum';

  @override
  String get placement => 'Poziționare';

  @override
  String get motion => 'Mișcare';

  @override
  String get zoomResponse => 'Răspuns la zoom';

  @override
  String get fixed => 'Fix';

  @override
  String get scaleWithZoom => 'Scalează odată cu zoomul';

  @override
  String get zoomScale => 'Scală zoom';

  @override
  String get intro => 'Intrare';

  @override
  String get outro => 'Ieșire';

  @override
  String get introDuration => 'Durată intrare';

  @override
  String get outroDuration => 'Durată ieșire';

  @override
  String get fade => 'Estompare';

  @override
  String get pop => 'Pop';

  @override
  String get slide => 'Glisare';

  @override
  String get shrink => 'Micșorare';

  @override
  String get zoomEmphasis => 'Accent zoom';

  @override
  String get pulse => 'Puls';

  @override
  String get pulseStrength => 'Intensitate puls';

  @override
  String get cameraNoAssetNotice =>
      'Nu a fost înregistrat un flux separat al camerei pentru acest clip.';

  @override
  String get cameraPlacementHelper =>
      'Ajustează sau mută poziția camerei pe ecran.';

  @override
  String get cameraBackgroundBehindHint =>
      'Aspectul de fundal umple întregul canvas. Alege un punct sau trage mânerul pentru a reveni la o poziție de suprapunere.';

  @override
  String get topLeft => 'Sus stânga';

  @override
  String get topCenter => 'Sus centru';

  @override
  String get topRight => 'Sus dreapta';

  @override
  String get centerLeft => 'Centru stânga';

  @override
  String get centerRight => 'Centru dreapta';

  @override
  String get bottomLeft => 'Jos stânga';

  @override
  String get bottomCenter => 'Jos centru';

  @override
  String get bottomRight => 'Jos dreapta';

  @override
  String get refreshDevicesTooltip => 'Reîmprospătare dispozitive (⌘R)';

  @override
  String get copyLastPathTooltip => 'Copiază ultima cale';

  @override
  String get timeline => 'Timeline';

  @override
  String get newRecording => 'Înregistrare nouă';

  @override
  String get newRecordingTooltip =>
      'Renunță la previzualizarea curentă și începe o înregistrare nouă';

  @override
  String get startNewRecordingTitle => 'Începi o înregistrare nouă?';

  @override
  String get startNewRecordingBody =>
      'Aceasta va închide previzualizarea curentă și va elimina orice modificări nesalvate. Exportă mai întâi dacă vrei să păstrezi această înregistrare.';

  @override
  String get keepEditing => 'Continuă editarea';

  @override
  String get discardPreview => 'Renunță la previzualizare';

  @override
  String get play => 'Redare';

  @override
  String get pausePlayback => 'Pauză';

  @override
  String get markers => 'Marcaje';

  @override
  String get lanes => 'Benzi';

  @override
  String get snap => 'Fixare';

  @override
  String get zoomAddSegment => 'Adaugă segment zoom';

  @override
  String get zoomAddOne => 'Adaugă unul';

  @override
  String get zoomKeepAdding => 'Continuă adăugarea';

  @override
  String get zoomKeepAddingTooltip => 'Continuă să adaugi segmente de zoom';

  @override
  String get zoomAddOneTooltip => 'Adaugă un singur segment de zoom';

  @override
  String get zoomAddOneStatus =>
      'Adaugă un zoom • Trage pe pista de zoom • Esc pentru anulare';

  @override
  String get zoomKeepAddingStatus =>
      'Continuă adăugarea zoomurilor • Trage pe pista de zoom • Esc pentru ieșire';

  @override
  String get zoomMoveStatus => 'Mutare zoom selectat';

  @override
  String get zoomTrimStartStatus => 'Decupare început zoom';

  @override
  String get zoomTrimEndStatus => 'Decupare sfârșit zoom';

  @override
  String get zoomBandSelectStatus => 'Selectare zoomuri';

  @override
  String get zoomSelectionTools => 'Instrumente de selecție';

  @override
  String get zoomDeleteSelectedOne => 'Șterge segmentul selectat';

  @override
  String zoomDeleteSelectedMany(int count) {
    return 'Șterge $count segmente';
  }

  @override
  String get zoomSelectAfterPlayhead => 'Selectează după indicator';

  @override
  String get zoomClearSelection => 'Șterge selecția';

  @override
  String zoomSelectedCount(int count) {
    return '$count selectate';
  }

  @override
  String get zoomSelectAllVisible => 'Selectează tot ce este vizibil';

  @override
  String get zoomUndoLastAction => 'Anulează ultima acțiune';

  @override
  String get zoomSelectionCleared => 'Selecția a fost ștearsă';

  @override
  String get zoomChangeSelectionRange => 'Schimbă intervalul selecției';

  @override
  String stopIn(Object value) {
    return 'Oprește în $value';
  }

  @override
  String get recording => 'Înregistrare';

  @override
  String get classic43 => 'Clasic (4:3)';

  @override
  String get classic => 'Clasic';

  @override
  String get square11 => 'Pătrat (1:1)';

  @override
  String get youtube169 => 'YouTube (16:9)';

  @override
  String get reel916 => 'Reel (9:16)';

  @override
  String get wide => 'Lat';

  @override
  String get vertical => 'Vertical';

  @override
  String get vertical4k => '4K vertical (2160x3840)';

  @override
  String get canvasAspect => 'Aspect canvas';

  @override
  String get fitMode => 'Mod de încadrare';

  @override
  String get fit => 'Încadrează';

  @override
  String get fill => 'Umple';

  @override
  String get recordingInProgress => 'ÎNREGISTRARE ÎN CURS';

  @override
  String get recordingPaused => 'ÎNREGISTRAREA ESTE ÎN PAUZĂ';

  @override
  String get readyToRecord => 'GATA DE ÎNREGISTRARE';

  @override
  String get pause => 'PAUZĂ';

  @override
  String get resume => 'REIA';

  @override
  String get paused => 'Pauză';

  @override
  String get stop => 'STOP';

  @override
  String get startRecording => 'ÎNCEPE ÎNREGISTRAREA';

  @override
  String get loading => 'Se încarcă…';

  @override
  String hoursShort(Object value) {
    return '$value h';
  }

  @override
  String minutesShort(Object value) {
    return '$value min';
  }

  @override
  String get off => 'Oprit';

  @override
  String get whileRecording => 'În timpul înregistrării';

  @override
  String get alwaysOn => 'Întotdeauna activ';

  @override
  String get general => 'General';

  @override
  String get settingsWorkspace => 'Spațiu de lucru';

  @override
  String get settingsWorkspaceDescription =>
      'Temă, limbă și comportamentul folderului de salvare.';

  @override
  String get settingsStorage => 'Stocare';

  @override
  String get settingsStorageDescription =>
      'Spațiu pentru înregistrări, utilizare internă și sănătatea discului.';

  @override
  String get settingsShortcutsDescription =>
      'Personalizează scurtăturile de tastatură și rezolvă conflictele.';

  @override
  String get settingsLicense => 'Licență';

  @override
  String get settingsLicenseDescription =>
      'Status plan, eligibilitate, legare dispozitiv și acțiuni de upgrade.';

  @override
  String get settingsPermissions => 'Permisiuni';

  @override
  String get settingsPermissionsDescription =>
      'Stare acces și scurtături către Setările Sistem.';

  @override
  String get settingsDiagnostics => 'Diagnosticare';

  @override
  String get settingsDiagnosticsDescription =>
      'Loguri și utilitare de depanare.';

  @override
  String get settingsAbout => 'Despre';

  @override
  String get settingsAboutDescription =>
      'Informații versiune, suport și linkuri legale.';

  @override
  String get permissionsTitle => 'Permisiuni';

  @override
  String get permissionsHelpText =>
      'Verifică ce permisiuni poate folosi Clingfy și deschide direct panoul relevant din Setările Sistem.';

  @override
  String get permissionsRefreshStatus => 'Actualizează starea';

  @override
  String get permissionsGranted => 'Acordată';

  @override
  String get permissionsNotGranted => 'Neacordată';

  @override
  String get permissionsRequired => 'Obligatorie';

  @override
  String get permissionsOptional => 'Opțională';

  @override
  String get permissionsScreenRecording => 'Înregistrare ecran';

  @override
  String get permissionsMicrophone => 'Microfon';

  @override
  String get permissionsCamera => 'Cameră';

  @override
  String get permissionsAccessibility => 'Accesibilitate';

  @override
  String get permissionsScreenRecordingHelp =>
      'Necesară pentru a captura un ecran, o fereastră sau o zonă selectată.';

  @override
  String get permissionsMicrophoneHelp =>
      'Permite includerea narațiunii tale vocale în înregistrări.';

  @override
  String get permissionsCameraHelp =>
      'Permite afișarea overlay-ului face-cam în timpul înregistrării.';

  @override
  String get permissionsAccessibilityHelp =>
      'Folosită pentru evidențierea clickurilor și efecte bazate pe cursor.';

  @override
  String get permissionsChangedHint =>
      'Dacă modifici o permisiune în Setările Sistem, revino în Clingfy și actualizează această pagină pentru a vedea starea curentă.';

  @override
  String get permissionsGrantAccess => 'Acordă acces';

  @override
  String get settingsLinks => 'Linkuri';

  @override
  String get appTheme => 'Temă Aplicație';

  @override
  String get appThemeDescription => 'Alegeți aspectul preferat';

  @override
  String get systemDefault => 'Implicit Sistem';

  @override
  String get light => 'Luminos';

  @override
  String get dark => 'Întunecat';

  @override
  String get appLanguage => 'Limba Aplicației';

  @override
  String get appLanguageDescription => 'Selectați limba pentru aplicație';

  @override
  String get english => 'Engleză';

  @override
  String get arabic => 'Arabă';

  @override
  String get romanian => 'Română';

  @override
  String get exportVideo => 'Exportă Video';

  @override
  String get close => 'Închide';

  @override
  String get cancel => 'Anulează';

  @override
  String get enterVideoName => 'Introduceți un nume pentru video:';

  @override
  String get filename => 'Nume fișier';

  @override
  String get matchSystem => 'Potrivește sistemul';

  @override
  String get keyboardShortcuts => 'Scurtături Tastatură';

  @override
  String get toggleRecording => 'Comutare Înregistrare';

  @override
  String get refreshDevices => 'Reîmprospătare Dispozitive';

  @override
  String get toggleActionBar => 'Comută bara de acțiuni';

  @override
  String get cycleOverlayMode => 'Comutare Mod Suprapunere';

  @override
  String get pressKeyToCapture =>
      'Apăsați o combinație de taste… Esc pentru anulare';

  @override
  String shortcutCollision(Object action) {
    return 'Scurtătura este deja utilizată de $action';
  }

  @override
  String get resetShortcuts => 'Resetare Scurtături';

  @override
  String get countdown => 'Numărătoare inversă';

  @override
  String seconds(Object value) {
    return '$value s';
  }

  @override
  String get recordingFolderBehavior => 'Comportament folder înregistrări';

  @override
  String get openFolderAfterStop =>
      'Deschide folderul după oprirea înregistrării';

  @override
  String get openFolderAfterExport =>
      'Deschide folderul după exportarea videoclipului';

  @override
  String get confirmations => 'Confirmări';

  @override
  String get warnBeforeClosingUnexportedRecording =>
      'Avertizează înainte de a închide o înregistrare neexportată';

  @override
  String get warnBeforeClosingUnexportedRecordingDescription =>
      'Afișează o confirmare înainte de a închide înregistrarea curentă dacă nu a fost exportată încă.';

  @override
  String get closeUnexportedRecordingTitle =>
      'Închizi înregistrarea fără export?';

  @override
  String get closeUnexportedRecordingMessage =>
      'Această înregistrare nu a fost încă exportată. Dacă o închizi acum, vei pierde accesul la ea în sesiunea curentă.';

  @override
  String get closeWithoutExporting => 'Închide fără export';

  @override
  String get doNotShowAgain => 'Nu mai arăta';

  @override
  String get aboutThisApp => 'Despre această aplicație';

  @override
  String get aboutClingfy => 'Despre Clingfy';

  @override
  String version(Object value) {
    return 'Versiune $value';
  }

  @override
  String get aboutDeveloperModeEnabled => 'Mod dezvoltator activat';

  @override
  String get aboutDeveloperModeDisabled => 'Mod dezvoltator dezactivat';

  @override
  String get aboutBuildMetadata => 'METADATE BUILD';

  @override
  String get aboutBuildCommit => 'Commit';

  @override
  String get aboutBuildBranch => 'Branch';

  @override
  String get aboutBuildId => 'Build ID';

  @override
  String get aboutBuildDate => 'Build realizat';

  @override
  String get checkForUpdates => 'Verifică actualizările';

  @override
  String get escToCancel => 'Esc pentru anulare';

  @override
  String get menuFile => 'Fișier';

  @override
  String get menuView => 'Vizualizare';

  @override
  String get showActionBar => 'Afișează bara de acțiuni';

  @override
  String get recordingSetupNeedsAttention =>
      'Configurarea înregistrării necesită atenția ta';

  @override
  String get storageOverviewTitle => 'Siguranța înregistrării';

  @override
  String get storageOverviewDescription =>
      'Monitorizează spațiul liber al sistemului și utilizarea spațiului Clingfy pentru a evita înregistrările eșuate.';

  @override
  String get storageSystemTitle => 'Stocare sistem';

  @override
  String get storageSystemDescription =>
      'Discul folosit de destinația activă de captură a Clingfy.';

  @override
  String get storageClingfyTitle => 'Stocare Clingfy';

  @override
  String get storageClingfyDescription =>
      'Înregistrări interne, capturi temporare și loguri.';

  @override
  String get storageActionsTitle => 'Acțiuni';

  @override
  String get storagePathsTitle => 'Căi';

  @override
  String get storageHealthy => 'Sănătos';

  @override
  String get storageWarning => 'Avertizare';

  @override
  String get storageCritical => 'Critic';

  @override
  String get storageHealthyMessage =>
      'Sistemul are suficient spațiu liber pentru înregistrări normale.';

  @override
  String get storageWarningMessage =>
      'Spațiul liber devine redus. Înregistrările lungi pot eșua.';

  @override
  String get storageCriticalMessage =>
      'Înregistrarea este blocată până când eliberezi mai mult spațiu.';

  @override
  String get storageRefresh => 'Reîmprospătează';

  @override
  String get storageOpenRecordingsFolder => 'Deschide folderul înregistrărilor';

  @override
  String get storageOpenTempFolder => 'Deschide folderul temporar';

  @override
  String get storageClearCachedRecordings => 'Șterge înregistrările din cache';

  @override
  String get storageClearCachedRecordingsConfirmTitle =>
      'Ștergi înregistrările din cache?';

  @override
  String get storageClearCachedRecordingsConfirmMessage =>
      'Aceasta elimină copiile interne ale înregistrărilor și fișierele sidecar ale Clingfy. Înregistrările exportate nu sunt șterse, iar acțiunea nu poate fi anulată.';

  @override
  String get storageClearCachedRecordingsConfirmAction =>
      'Șterge înregistrările';

  @override
  String storageClearCachedRecordingsSuccess(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Au fost eliminate $count înregistrări din cache.',
      one: 'A fost eliminată 1 înregistrare din cache.',
    );
    return '$_temp0';
  }

  @override
  String get storageStatusLabel => 'Stare';

  @override
  String get storageTotalSpace => 'Total';

  @override
  String get storageUsedSpace => 'Folosit';

  @override
  String get storageFreeSpace => 'Liber';

  @override
  String get storageRecordings => 'Înregistrări';

  @override
  String get storageTemp => 'Temporar';

  @override
  String get storageLogs => 'Loguri';

  @override
  String get storageClingfyTotal => 'Utilizare totală Clingfy';

  @override
  String get storageRecordingsPath => 'Folder înregistrări';

  @override
  String get storageTempPath => 'Folder temporar';

  @override
  String get storageLogsPath => 'Folder loguri';

  @override
  String get storageActionFailed => 'Acțiunea de stocare a eșuat.';

  @override
  String storageFreeNow(String value) {
    return 'Liber acum: $value';
  }

  @override
  String get missingRequiredPermission => 'Permisiune necesară lipsă';

  @override
  String get missingOptionalPermissionsForRequestedFeatures =>
      'Permisiuni opționale lipsă pentru funcțiile solicitate';

  @override
  String get grantPermissions => 'Acordă permisiunile';

  @override
  String get recordWithoutMissingFeatures =>
      'Înregistrează fără funcțiile lipsă';

  @override
  String get storagePreflightTitle => 'Stocarea necesită atenția ta';

  @override
  String get storagePreflightCriticalIntro =>
      'Clingfy a detectat spațiu liber critic de redus pe discul activ de înregistrare. Înregistrarea este blocată pentru a evita capturi eșuate.';

  @override
  String get storagePreflightWarningIntro =>
      'Spațiul liber devine redus. Înregistrările lungi pot eșua înainte să se termine.';

  @override
  String get storageAvailableNow => 'Disponibil acum';

  @override
  String get storageRecordingBlockedBelow => 'Înregistrarea este blocată sub';

  @override
  String get storageRecommendedFreeSpace => 'Spațiu liber recomandat';

  @override
  String get openStorageSettings => 'Deschide Setările de Stocare';

  @override
  String get recordAnyway => 'Înregistrează oricum';

  @override
  String get storageBypassAndRecord => 'Ocolește și înregistrează';

  @override
  String get cameraForFaceCam => 'Camera pentru Face Cam';

  @override
  String get microphoneForVoice => 'Microfonul pentru voce';

  @override
  String get accessibilityForCursorHighlight =>
      'Accesibilitate pentru evidențierea cursorului';

  @override
  String get menuRecord => 'Înregistrare';

  @override
  String get unknown => 'Necunoscut';

  @override
  String get none => 'Niciunul';

  @override
  String get appDescription =>
      'Un înregistrator de ecran simplu și puternic pentru macOS.';

  @override
  String get visitWebsite => 'Vizitați Website-ul';

  @override
  String get contactSupport => 'Contactați Asistența';

  @override
  String get privacyPolicy => 'Politica de Confidențialitate';

  @override
  String get termsOfService => 'Termeni și Condiții';

  @override
  String get locationLabel => 'Locație:';

  @override
  String get changeButtonLabel => 'Schimbă...';

  @override
  String get cancelExport => 'Anulează Exportul';

  @override
  String get cancelExportConfirm =>
      'Sigur doriți să opriți procesul de export?';

  @override
  String get keepExporting => 'Continuă Exportul';

  @override
  String get stopExport => 'Oprește Exportul';

  @override
  String get runInBackground => 'Rulează în fundal';

  @override
  String get hideProgress => 'Ascunde progresul';

  @override
  String get showProgress => 'Afișează progresul';

  @override
  String get cancelingExport => 'Se anulează exportul...';

  @override
  String get exportAlreadyInProgress => 'Un export este deja în desfășurare.';

  @override
  String get errAlreadyRecording => 'O înregistrare este deja în curs.';

  @override
  String get errNoWindowSelected =>
      'Vă rugăm să selectați o fereastră pentru înregistrare.';

  @override
  String get errNoAreaSelected =>
      'Vă rugăm să selectați o zonă pentru înregistrare mai întâi.';

  @override
  String get errTargetError => 'Nu s-a putut determina ținta înregistrării.';

  @override
  String get errNotRecording => 'Nu există nicio înregistrare activă de oprit.';

  @override
  String get errInvalidRecordingState =>
      'Această acțiune nu este disponibilă în starea curentă a înregistrării.';

  @override
  String get errPauseResumeUnsupported =>
      'Pauza și reluarea nu sunt acceptate pentru configurația curentă de înregistrare.';

  @override
  String get errUnknownAudioDevice =>
      'Dispozitivul audio selectat este indisponibil.';

  @override
  String get errBadQuality => 'Calitate de înregistrare nevalidă.';

  @override
  String get errScreenRecordingPermission =>
      'Activați Înregistrarea Ecranului în Setări Sistem > Confidențialitate și Securitate > Înregistrare Ecran, apoi încercați din nou.';

  @override
  String get errWindowUnavailable =>
      'Fereastra selectată nu mai este disponibilă. Reîmprospătați lista și selectați-o din nou.';

  @override
  String errRecordingError(Object error) {
    return 'A apărut o eroare la înregistrare: $error';
  }

  @override
  String errOutputUrlError(Object error) {
    return 'Nu s-a putut crea fișierul de ieșire: $error';
  }

  @override
  String get errAccessibilityPermissionRequired =>
      'Activați Accesibilitatea pentru evidențierea cursorului în Setări Sistem, apoi reporniți aplicația.';

  @override
  String get errMicrophonePermissionRequired =>
      'Activați accesul la microfon în Setări Sistem > Confidențialitate și Securitate > Microfon, apoi încercați din nou.';

  @override
  String get recordingSelectedMicFallbackWarning =>
      'Microfonul selectat nu a putut fi folosit. Înregistrarea a început cu microfonul implicit al sistemului.';

  @override
  String get recordingSelectedMicFallbackFailure =>
      'Microfonul selectat nu a putut fi folosit pentru înregistrare. Alegeți alt microfon sau dezactivați înregistrarea microfonului.';

  @override
  String errExportError(Object error) {
    return 'A apărut o eroare la export: $error';
  }

  @override
  String get errCameraPermissionDenied =>
      'Activați camera în Setări Sistem > Confidențialitate și Securitate > Cameră.';

  @override
  String get shape => 'Formă';

  @override
  String get squircle => 'Squircle';

  @override
  String get circle => 'Cerc';

  @override
  String get roundedRect => 'Dreptunghi rotunjit';

  @override
  String get square => 'Pătrat';

  @override
  String get hexagon => 'Hexagon';

  @override
  String get star => 'Stea';

  @override
  String cornerRoundness(Object value) {
    return 'Rotunjire colțuri: $value%';
  }

  @override
  String sizePx(Object value) {
    return 'Dimensiune: ${value}px';
  }

  @override
  String opacityPercent(Object value) {
    return 'Opacitate: $value%';
  }

  @override
  String get opacity => 'Opacitate';

  @override
  String get mirrorSelfView => 'Oglindire vizualizare';

  @override
  String get chromaKey => 'Chroma key (ecran verde)';

  @override
  String keyTolerance(Object value) {
    return 'Toleranță cheie: $value%';
  }

  @override
  String get keyToleranceLabel => 'Toleranță cheie';

  @override
  String get chromaKeyColor => 'Culoare chroma key';

  @override
  String get pickChromaKeyColor => 'Alege culoarea chroma key';

  @override
  String get targetColorToRemove => 'Culoarea țintă de eliminat';

  @override
  String get position => 'Poziție';

  @override
  String get customPosition => 'Poziție personalizată';

  @override
  String get customPositionHint =>
      'Trasează manual sau alege un colț pentru a reveni.';

  @override
  String get shadow => 'Umbră';

  @override
  String get border => 'Bordură';

  @override
  String get pickBorderColor => 'Alege culoarea bordurii';

  @override
  String borderWidth(Object value) {
    return 'Lățime bordură: $value px';
  }

  @override
  String get borderWidthLabel => 'Lățime bordură';

  @override
  String get diagnosticsTitle => 'Diagnosticare';

  @override
  String get diagnosticsHelpText =>
      'Dacă ceva nu merge bine, deschideți folderul de loguri și trimiteți logul de astăzi la suport.';

  @override
  String get openLogsFolder => 'Deschide folderul de loguri';

  @override
  String get revealTodayLog => 'Arată logul de astăzi';

  @override
  String get copyLogPath => 'Copiază calea';

  @override
  String get errVideoFileMissing =>
      'Fișierul de înregistrare a fost mutat sau șters.';

  @override
  String get errCursorFileMissing =>
      'Datele cursorului lipsesc. Efectele cursorului sunt dezactivate.';

  @override
  String get errExportInputMissing =>
      'Fișierul de înregistrare nu a fost găsit. Este posibil să fi fost mutat sau șters.';

  @override
  String get errAssetInvalid => 'Nu s-a putut pregăti previzualizarea video.';

  @override
  String get applyEffects => 'Aplică Efectele';

  @override
  String get recordingSaved => 'Înregistrare salvată:';

  @override
  String get externalProjectOpenBlocked =>
      'Finalizează înregistrarea curentă sau tranziția previzualizării înainte de a deschide alt proiect.';

  @override
  String get externalProjectOpenFailed =>
      'Acest proiect Clingfy nu a putut fi deschis.';

  @override
  String get exportSuccess => 'Export reușit:';

  @override
  String get open => 'Deschide';

  @override
  String get cursorDataMissing => 'Datele cursorului lipsesc';

  @override
  String get voiceBoost => 'Amplificare Voce';

  @override
  String get audioGain => 'Câștig Audio';

  @override
  String get volume => 'Volum';

  @override
  String get micInputLevel => 'Nivel intrare microfon';

  @override
  String get micInputIndicatorDisabledTooltip =>
      'Selectează un microfon pentru a previzualiza nivelul de intrare.';

  @override
  String micInputIndicatorLiveTooltip(String dbfs) {
    return 'Nivel intrare microfon: $dbfs dBFS';
  }

  @override
  String get micInputIndicatorLowTooltip =>
      'Intrarea microfonului este foarte mică. Crește nivelul de intrare sau apropie-te de microfon.';

  @override
  String get noMicAudioFound => 'Nu s-a găsit nicio pistă audio de microfon';

  @override
  String get autoNormalizeOnExport => 'Auto-normalizare la export';

  @override
  String get targetLoudness => 'Volum țintă';

  @override
  String get selectCameraHint =>
      'Selectați o cameră pentru a configura setările de suprapunere';

  @override
  String get closePreview => 'Închide Previzualizarea';

  @override
  String get preparingPreview => 'Se pregătește previzualizarea...';

  @override
  String get menuStartRecording => 'Începe Înregistrarea';

  @override
  String get menuStopRecording => 'Oprește Înregistrarea';

  @override
  String get menuOpenApp => 'Deschide Clingfy';

  @override
  String get menuQuit => 'Închide Clingfy';

  @override
  String get captureSettings => 'Setări Captură';

  @override
  String get captureSettingsDescription =>
      'Configurați comportamentul capturii de ecran.';

  @override
  String get excludeRecorderAppFromCapture =>
      'Exclude aplicația de înregistrare din captură';

  @override
  String get excludeRecorderAppFromCaptureDescription =>
      'Când este activat, fereastra înregistratorului este ascunsă din înregistrări. Dezactivați pentru a o include (util pentru tutoriale despre această aplicație).';

  @override
  String get ok => 'OK';

  @override
  String get copy => 'Copiază';

  @override
  String get copiedToClipboard => 'Copiat în clipboard';

  @override
  String get loadingYourSettings => 'Se încarcă setările...';

  @override
  String get renderingErrorFallbackMessage =>
      'A apărut o eroare de randare.\nVerificați logurile pentru detalii.';

  @override
  String get debugResetPreferencesTitle => 'Resetezi preferințele?';

  @override
  String get debugResetPreferencesMessage =>
      'Aceasta șterge toate setările salvate.';

  @override
  String get debugResetPreferencesConfirm => 'Resetează';

  @override
  String get debugResetPreferencesSemanticLabel =>
      'Resetează preferințele (Debug)';

  @override
  String get diagnosticsLogFileNotFound =>
      'Fișierul log nu a fost găsit. Încercați să reproduceți problema mai întâi.';

  @override
  String get diagnosticsLogFileUnavailable =>
      'Calea fișierului log nu este disponibilă momentan.';

  @override
  String get diagnosticsActionFailed => 'Acțiunea nu a putut fi finalizată.';

  @override
  String get diagnosticsLogRevealed => 'Fișierul log de astăzi a fost afișat.';

  @override
  String get recordingSystemAudio => 'Audio de sistem';

  @override
  String get recordingExcludeMicFromSystemAudio =>
      'Exclude microfonul meu din audio de sistem';

  @override
  String get restartApp => 'Repornește aplicația';

  @override
  String get permissionsOnboardingWelcomeRail => 'Bun venit';

  @override
  String get permissionsOnboardingMicCameraRail => 'Mic + Cameră';

  @override
  String permissionsOnboardingStepLabel(int current) {
    return 'Pasul $current din 4';
  }

  @override
  String get permissionsOnboardingWelcomeTitle => 'Bun venit la Clingfy';

  @override
  String get permissionsOnboardingWelcomeSubtitle =>
      'O configurare rapidă și ești gata să înregistrezi în câteva minute.';

  @override
  String get permissionsOnboardingTrustLocalFirst =>
      'Local-first: înregistrările rămân pe Mac-ul tău.';

  @override
  String get permissionsOnboardingTrustPermissionControl =>
      'Controlezi permisiunile oricând din Setările de sistem.';

  @override
  String get permissionsOnboardingFeatureExportsTitle => 'Exporturi clare 4K+';

  @override
  String get permissionsOnboardingFeatureExportsSubtitle =>
      'Presetări pentru YouTube, reels și multe altele.';

  @override
  String get permissionsOnboardingFeatureZoomTitle =>
      'Zoom-follow + efecte pentru cursor';

  @override
  String get permissionsOnboardingFeatureZoomSubtitle =>
      'Îi ajută pe spectatori să urmărească ce contează.';

  @override
  String get permissionsOnboardingScreenTitle =>
      'Înregistrarea ecranului (Obligatoriu)';

  @override
  String get permissionsOnboardingScreenSubtitle =>
      'macOS cere asta înainte de a începe orice înregistrare. Durează cam 15 secunde.';

  @override
  String get permissionsOnboardingWhyAreYouAsking => 'De ce cereți asta?';

  @override
  String get permissionsOnboardingWhyIsThisNeeded =>
      'De ce este nevoie de asta?';

  @override
  String get permissionsOnboardingWhyScreenTitle =>
      'De ce Înregistrarea ecranului?';

  @override
  String get permissionsOnboardingWhyScreenSubtitle =>
      'Această permisiune este cerută de macOS pentru a captura pixelii de pe ecran.';

  @override
  String get permissionsOnboardingWhyScreenBullet1 =>
      'Necesară pentru captură de ecran complet, fereastră și zonă personalizată.';

  @override
  String get permissionsOnboardingWhyScreenBullet2 =>
      'Clingfy înregistrează local; exportul este ceva ce inițiezi tu.';

  @override
  String get permissionsOnboardingWhyScreenBullet3 =>
      'O poți dezactiva oricând din Setările de sistem.';

  @override
  String get permissionsOnboardingWhyScreenFooter =>
      'Dacă macOS afișează un comutator pentru Clingfy, asigură-te că este activ.';

  @override
  String get permissionsOnboardingScreenTrustLine1 =>
      'Local-first: înregistrările rămân pe Mac-ul tău.';

  @override
  String get permissionsOnboardingScreenTrustLine2 =>
      'Deții mereu controlul — poți schimba asta oricând.';

  @override
  String get permissionsOnboardingRestartHint =>
      'Dacă macOS afișează un comutator, asigură-te că este activ. Poate fi nevoie să repornești Clingfy.';

  @override
  String get permissionsOnboardingVoiceCameraTitle =>
      'Voce și face-cam (Opțional)';

  @override
  String get permissionsOnboardingVoiceCameraSubtitle =>
      'Recomandat pentru tutoriale, dar poți sări peste acest pas și activa mai târziu.';

  @override
  String get permissionsOnboardingMicrophoneDescription =>
      'Pentru narațiune și amplificare vocală.';

  @override
  String get permissionsOnboardingEnableMic => 'Activează microfonul';

  @override
  String get permissionsOnboardingWhyMicrophoneTitle => 'De ce Microfonul?';

  @override
  String get permissionsOnboardingWhyMicrophoneSubtitle =>
      'Pentru ca înregistrările să includă vocea ta.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet1 =>
      'Folosit doar când activezi înregistrarea cu microfonul.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet2 =>
      'Poți alege dispozitivul de intrare în aplicație.';

  @override
  String get permissionsOnboardingWhyMicrophoneBullet3 =>
      'Poți revoca permisiunea oricând.';

  @override
  String get permissionsOnboardingCameraDescription =>
      'Afișează-ți fața într-o bulă personalizabilă.';

  @override
  String get permissionsOnboardingEnableCamera => 'Activează camera';

  @override
  String get permissionsOnboardingWhyCameraTitle => 'De ce Camera?';

  @override
  String get permissionsOnboardingWhyCameraSubtitle =>
      'Pentru suprapuneri face-cam (opțional).';

  @override
  String get permissionsOnboardingWhyCameraBullet1 =>
      'Este folosită doar când activezi bula camerei.';

  @override
  String get permissionsOnboardingWhyCameraBullet2 =>
      'O poți opri oricând în timpul înregistrării.';

  @override
  String get permissionsOnboardingWhyCameraBullet3 =>
      'Poți revoca permisiunea oricând.';

  @override
  String get permissionsOnboardingAudioTrustLine1 =>
      'Pas opțional — poți înregistra fără microfon sau cameră.';

  @override
  String get permissionsOnboardingAudioTrustLine2 =>
      'Le poți activa mai târziu oricând din setările aplicației.';

  @override
  String get permissionsOnboardingCursorTitle => 'Cursor Magic (Opțional)';

  @override
  String get permissionsOnboardingCursorSubtitle =>
      'Activează evidențierea clicurilor și mișcarea mai fluidă a cursorului pentru spectatori.';

  @override
  String get permissionsOnboardingAccessibilityDescription =>
      'Folosit pentru a detecta clicurile mouse-ului pentru efectele cursorului.';

  @override
  String get permissionsOnboardingCheck => 'Verifică';

  @override
  String get permissionsOnboardingWhyAccessibilityTitle =>
      'De ce Accesibilitate?';

  @override
  String get permissionsOnboardingWhyAccessibilitySubtitle =>
      'macOS grupează accesul la evenimentele mouse-ului sub permisiunile de Accesibilitate.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet1 =>
      'Folosit pentru evidențierea clicurilor și efectele Cursor Magic.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet2 =>
      'Recomandat pentru tutoriale și demo-uri, dar nu este necesar pentru înregistrare.';

  @override
  String get permissionsOnboardingWhyAccessibilityBullet3 =>
      'Îl poți revoca oricând din Setările de sistem.';

  @override
  String get permissionsOnboardingCursorTrustLine1 =>
      'Pas opțional — înregistrările funcționează și fără el.';

  @override
  String get permissionsOnboardingCursorTrustLine2 =>
      'Poți activa Cursor Magic mai târziu, când vrei.';

  @override
  String get permissionsOnboardingSkipForNow => 'Omite deocamdată';

  @override
  String get permissionsOnboardingBack => 'Înapoi';

  @override
  String get permissionsOnboardingNext => 'Continuă';

  @override
  String get permissionsOnboardingLetsRecord => 'Hai să înregistrăm! 🚀';

  @override
  String get quickTour => 'Tur rapid';

  @override
  String get back => 'Înapoi';

  @override
  String get next => 'Următorul';

  @override
  String get skip => 'Omite';

  @override
  String get done => 'Gata';

  @override
  String homeGuideStepCounter(int current, int total) {
    return 'Pasul $current din $total';
  }

  @override
  String get homeGuideSidebarTitle =>
      'Această bară laterală păstrează întregul flux de înregistrare la îndemână.';

  @override
  String get homeGuideSidebarBody =>
      'Folosește aceste butoane pentru a schimba secțiunile de configurare, a deschide Ajutorul și a intra în setări fără să ieși din recorder.';

  @override
  String get homeGuideCaptureSourceTitle =>
      'Alege aici ce înregistrează Clingfy.';

  @override
  String get homeGuideCaptureSourceBody =>
      'Selectează un ecran, o singură fereastră sau o zonă personalizată înainte să începi înregistrarea.';

  @override
  String get homeGuideCameraTitle =>
      'Activează camera doar când ai nevoie de ea.';

  @override
  String get homeGuideCameraBody =>
      'Alege o cameră, apoi ajustează overlay-ul dacă vrei să apari în tutoriale sau demo-uri.';

  @override
  String get homeGuideOutputTitle =>
      'Setează valorile implicite înainte să apeși Record.';

  @override
  String get homeGuideOutputBody =>
      'Aici găsești countdown și auto-stop, ca fiecare înregistrare să pornească exact cum te aștepți.';

  @override
  String get homeGuideStartRecordingTitle =>
      'Acesta este controlul principal pentru înregistrare.';

  @override
  String get homeGuideStartRecordingBody =>
      'Când sursa arată corect, pornește de aici. Tot aici vei putea apoi să pui pauză sau să oprești.';

  @override
  String get homeGuideHelpTitle => 'Poți relua turul oricând din Ajutor.';

  @override
  String get homeGuideHelpBody =>
      'Deschide Ajutor pentru o recapitulare rapidă sau mergi la Despre când ai nevoie de versiune și detalii de suport.';

  @override
  String get homeGuideReplayUnavailable =>
      'Revino la configurarea înregistrării pentru a relua turul rapid.';

  @override
  String get window => 'Fereastră';

  @override
  String get area => 'Zonă';

  @override
  String get mic => 'Microfon';

  @override
  String get system => 'Sistem';

  @override
  String get update => 'Actualizare';

  @override
  String get screen => 'Ecran';

  @override
  String get app => 'Aplicație';

  @override
  String get selectDisplay => 'Selectează ecranul';

  @override
  String get selectWindow => 'Selectează fereastra';

  @override
  String get selectMicrophone => 'Selectează microfonul';

  @override
  String get selectCamera => 'Selectează camera';

  @override
  String get unknownDisplay => 'Ecran necunoscut';

  @override
  String get unknownWindow => 'Fereastră necunoscută';

  @override
  String get unknownMic => 'Microfon necunoscut';

  @override
  String get unknownCamera => 'Cameră necunoscută';

  @override
  String get noCamera => 'Fără cameră';

  @override
  String get doNotRecordAudio => 'Nu înregistra audio';

  @override
  String get stoppingEllipsis => 'Se oprește...';

  @override
  String get pauseRecording => 'Pune pauză înregistrării';

  @override
  String get resumeRecording => 'Reia înregistrarea';

  @override
  String get recordingInProgressLabel => 'Înregistrare în curs';

  @override
  String get recordingPausedLabel => 'Înregistrare în pauză';

  @override
  String get stoppingRecording => 'Se oprește înregistrarea';

  @override
  String get recordingIndicatorHelpPause =>
      'Acțiunea principală pune pauză înregistrării. Controlul secundar oprește înregistrarea.';

  @override
  String get recordingIndicatorHelpResume =>
      'Acțiunea principală reia înregistrarea. Controlul secundar oprește înregistrarea.';

  @override
  String get recordingIndicatorHelpStopping => 'Înregistrarea se oprește.';

  @override
  String get defaultExportFileNameLabel => 'Export';

  @override
  String get defaultClipFileNameLabel => 'Clip';

  @override
  String get licenseInitializing => 'Se inițializează...';

  @override
  String get licenseInternetRequired =>
      'Este necesară conexiunea la internet pentru verificarea licenței.';

  @override
  String get licenseOfflineCached => 'Mod offline (din cache)';

  @override
  String get licenseValidationFailed => 'Nu s-a putut valida licența.';

  @override
  String get licenseTrialConsumptionFailed =>
      'Nu s-a putut sincroniza utilizarea trial.';

  @override
  String get licenseNetworkUnavailableWhileConsumingTrial =>
      'Rețeaua nu este disponibilă în timpul sincronizării utilizării trial.';

  @override
  String get licenseNetworkUnavailableWhileDeactivatingDevice =>
      'Rețeaua nu este disponibilă în timpul dezactivării dispozitivului.';

  @override
  String get licenseValidated => 'Licența a fost validată.';

  @override
  String get licenseNotEntitled =>
      'Această licență nu deblochează funcțiile Pro.';
}
