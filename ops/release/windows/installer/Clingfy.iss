; Clingfy.iss
;
; Phase 10.5 (Windows installer + release pipeline): Inno Setup script for the
; Clingfy per-user installer. Compiled by 02_package_inno.ps1, which passes
; every identity define below; the #ifndef defaults match the dev channel so
; `ISCC.exe Clingfy.iss` also works standalone after 01_build.ps1 -Channel dev.
;
; Locked decisions this file implements (docs/decisions/windows-phase-10-beta-
; readiness-plan.md, D1/D9/D10):
;   * Inno Setup, per-user, NOT MSIX — PrivilegesRequired=lowest, no UAC at
;     install or update; install dir {userpf} = %LOCALAPPDATA%\Programs.
;   * Windows 10 1903+ (build 18362, Windows Graphics Capture), x64 only.
;   * HKCU .clingfyproj association — the runner already handles both the
;     cold-start argv path and WM_COPYDATA forwarding to a running instance
;     (windows/runner/main.cpp); only this registry metadata was missing.
;   * Uninstall leftover policy: the uninstaller removes ONLY the install
;     directory, shortcuts, and the registry association. It deliberately
;     preserves user data:
;       %LOCALAPPDATA%\Clingfy\          recordings + native logs
;       %APPDATA%\com.clingfy\clingfy\   Dart logs, prefs, secure storage
;       %TEMP%\clingfy_*                 transient capture temps
;       Videos\Clingfy                   exported videos
;   * Dev/prod channels install side by side (distinct AppId, name, dir), but
;     they still share the single-instance mutex and data dirs until the D9
;     per-config identity plumbing lands in the runner.

#ifndef MyAppId
  #define MyAppId "{B6B2A6F2-42C3-4CB7-A01A-E3D904AE54AA}"
#endif
#ifndef MyAppName
  #define MyAppName "Clingfy Dev"
#endif
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyBuildNumber
  #define MyBuildNumber "0"
#endif
#ifndef MyAppVersionFull
  #define MyAppVersionFull MyAppVersion + "+" + MyBuildNumber
#endif
#ifndef MyProgId
  #define MyProgId "ClingfyDev.Project"
#endif
; Channel-unique key for the Directory right-click verb ("Open in <app>").
; Derived from MyProgId so 02_package_inno.ps1 needs no extra define.
#define MyDirVerbKey MyProgId + ".OpenFolder"
#ifndef StagingDir
  #define StagingDir SourcePath + "\..\..\..\..\dist\windows\app"
#endif
#ifndef MyOutputBaseFilename
  #define MyOutputBaseFilename "Clingfy_Dev_Setup_" + MyAppVersionFull
#endif

[Setup]
; AppId is the installer's stable identity: Inno upgrades an existing install
; in place when the AppId matches. One GUID per channel, never changed.
AppId={{#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersionFull}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=Clingfy
VersionInfoVersion={#MyAppVersion}.{#MyBuildNumber}
DefaultDirName={userpf}\{#MyAppName}
; Per-user everywhere: no UAC prompt at install time, and none at any future
; in-app update. This is load-bearing for the updater plan (D2).
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 1903 — Windows Graphics Capture minimum (D10).
MinVersion=10.0.18362
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
DisableProgramGroupPage=yes
DisableDirPage=auto
; Default for direct ISCC runs; 02_package_inno.ps1 overrides with /O. Keeps
; stray Output/ folders out of the repo tree (.gitignore only covers /dist).
OutputDir={#SourcePath}\..\..\..\..\dist\windows\installer
OutputBaseFilename={#MyOutputBaseFilename}
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\clingfy.exe
; Brand the setup/uninstall executables with the app icon (same multi-size
; .ico the runner embeds, generated from the macOS AppIcon.appiconset art).
SetupIconFile={#SourcePath}\..\..\..\..\windows\runner\resources\app_icon.ico
; Use the Restart Manager so upgrading over a running Clingfy closes it
; cleanly instead of failing on locked files (update-over-update gate, D2).
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
; The optional clipath task edits HKCU\Environment Path; this makes Inno
; broadcast WM_SETTINGCHANGE at the end of install so NEW terminals see it.
ChangesEnvironment=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
; Optional terminal launcher: ships {app}\bin\clingfy.{cmd,ps1} (always) and,
; when selected, appends {app}\bin to the USER Path so `clingfy .` opens the
; project in the current directory. Per-user (HKCU), matching
; PrivilegesRequired=lowest; removed again at uninstall by the [Code] below.
Name: "clipath"; Description: "Add the ""clingfy"" command to PATH (open projects from the terminal)"; GroupDescription: "Terminal:"; Flags: unchecked

[InstallDelete]
; Upgrades install over the existing {app}, and Inno never deletes files the
; new build stopped shipping — renamed plugin DLLs or dropped flutter_assets
; would otherwise accumulate forever and defeat the "installer ships the
; staged folder verbatim" invariant. {app} holds zero user data (recordings
; and prefs live under %LOCALAPPDATA%/%APPDATA%), so this cleanup is safe.
; Every surviving file is re-shipped by [Files] in the same transaction.
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\bin"
Type: files; Name: "{app}\*.dll"

[Files]
; The staged app folder produced by 01_build.ps1 — already excludes PDBs,
; runner_bridge.lib, and native_assets.json, and includes the app-local
; VC++ CRT. The installer ships it verbatim.
Source: "{#StagingDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
; The terminal launcher (tools/cli). Shipped unconditionally (tiny); only the
; PATH edit is gated on the clipath task. The .ps1 prefers {app}\clingfy.exe
; when run from {app}\bin, so each channel's shim opens its own channel.
Source: "{#SourcePath}\..\..\..\..\tools\cli\clingfy.cmd"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#SourcePath}\..\..\..\..\tools\cli\clingfy.ps1"; DestDir: "{app}\bin"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#MyAppName}"; Filename: "{app}\clingfy.exe"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\clingfy.exe"; Tasks: desktopicon

[Registry]
; .clingfyproj association (HKCU\Software\Classes — per-user, matching
; PrivilegesRequired=lowest). Double-click and "Open with" reach the runner's
; existing argv/WM_COPYDATA project-open plumbing.
;
; The extension entry deliberately has NO uninsdeletevalue: with dev + prod
; side by side (or a third-party handler), an unconditional delete at
; uninstall would clobber the SURVIVING channel's association. The [Code]
; handler below removes the value only when it still points at this
; channel's ProgId.
Root: HKA; Subkey: "Software\Classes\.clingfyproj"; ValueType: string; ValueName: ""; ValueData: "{#MyProgId}"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\{#MyProgId}"; ValueType: string; ValueName: ""; ValueData: "Clingfy Project"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\{#MyProgId}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\clingfy.exe,0"
Root: HKA; Subkey: "Software\Classes\{#MyProgId}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\clingfy.exe"" ""%1"""
;
; Right-click "Open in {#MyAppName}" on .clingfyproj bundle FOLDERS.
; Recordings are directories, and Windows extension associations fire for
; FILES only — Explorer double-click on a bundle folder navigates into it
; (macOS gets folder-as-document behavior from com.apple.package semantics
; that Windows lacks). This verb is the Windows-native way in: AppliesTo
; filters it to *.clingfyproj folders, and the runner already accepts a
; bundle directory path via argv (Core/argv_project_path.cpp has no
; file/dir check). On Windows 11 classic verbs sit under "Show more
; options". The key name is channel-unique, so plain uninsdeletekey is
; safe here (unlike the shared .clingfyproj extension value above).
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#MyDirVerbKey}"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Open in {#MyAppName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#MyDirVerbKey}"; ValueType: string; ValueName: "AppliesTo"; ValueData: "System.FileName:""*.clingfyproj"""
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#MyDirVerbKey}"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\clingfy.exe"",0"
Root: HKA; Subkey: "Software\Classes\Directory\shell\{#MyDirVerbKey}\command"; ValueType: string; ValueName: ""; ValueData: """{app}\clingfy.exe"" ""%1"""

[Run]
Filename: "{app}\clingfy.exe"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// ---- clipath task: {app}\bin on the USER Path -----------------------------
// HKCU\Environment (per-user, no elevation). Append is idempotent
// (case-insensitive segment check); removal rebuilds the value segment by
// segment so it never corrupts neighbors regardless of position or stray
// separators, and runs unconditionally at uninstall (a no-op when the task
// was never selected).

const
  EnvRegKey = 'Environment';

procedure AddCliBinToPath();
var
  Path, BinDir: string;
begin
  BinDir := ExpandConstant('{app}\bin');
  if not RegQueryStringValue(HKCU, EnvRegKey, 'Path', Path) then
    Path := '';
  if Pos(';' + Lowercase(BinDir) + ';', ';' + Lowercase(Path) + ';') > 0 then
    exit;
  if (Path <> '') and (Path[Length(Path)] <> ';') then
    Path := Path + ';';
  RegWriteExpandStringValue(HKCU, EnvRegKey, 'Path', Path + BinDir);
end;

procedure RemoveCliBinFromPath();
var
  Path, Bin, Rebuilt, Seg: string;
  I: Integer;
begin
  if not RegQueryStringValue(HKCU, EnvRegKey, 'Path', Path) then
    exit;
  Bin := Lowercase(ExpandConstant('{app}\bin'));
  Rebuilt := '';
  Seg := '';
  for I := 1 to Length(Path) + 1 do
  begin
    if (I > Length(Path)) or (Path[I] = ';') then
    begin
      if (Seg <> '') and (Lowercase(Seg) <> Bin) then
      begin
        if Rebuilt <> '' then
          Rebuilt := Rebuilt + ';';
        Rebuilt := Rebuilt + Seg;
      end;
      Seg := '';
    end
    else
      Seg := Seg + Path[I];
  end;
  if Rebuilt <> Path then
    RegWriteExpandStringValue(HKCU, EnvRegKey, 'Path', Rebuilt);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('clipath') then
    AddCliBinToPath();
end;

// Uninstall-time association cleanup: delete the .clingfyproj default value
// only if it still equals this channel's ProgId. If another channel (or any
// other app) owns the extension by now, leave it alone. Also drops
// {app}\bin from the user Path (no-op when the clipath task was never
// selected).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CurrentProgId: string;
begin
  if CurUninstallStep = usUninstall then
  begin
    if RegQueryStringValue(HKA, 'Software\Classes\.clingfyproj', '', CurrentProgId) and
       (CurrentProgId = '{#MyProgId}') then
      RegDeleteValue(HKA, 'Software\Classes\.clingfyproj', '');
    RemoveCliBinFromPath();
  end;
end;
