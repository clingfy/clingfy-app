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
; Use the Restart Manager so upgrading over a running Clingfy closes it
; cleanly instead of failing on locked files (update-over-update gate, D2).
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Upgrades install over the existing {app}, and Inno never deletes files the
; new build stopped shipping — renamed plugin DLLs or dropped flutter_assets
; would otherwise accumulate forever and defeat the "installer ships the
; staged folder verbatim" invariant. {app} holds zero user data (recordings
; and prefs live under %LOCALAPPDATA%/%APPDATA%), so this cleanup is safe.
; Every surviving file is re-shipped by [Files] in the same transaction.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"

[Files]
; The staged app folder produced by 01_build.ps1 — already excludes PDBs,
; runner_bridge.lib, and native_assets.json, and includes the app-local
; VC++ CRT. The installer ships it verbatim.
Source: "{#StagingDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

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

[Run]
Filename: "{app}\clingfy.exe"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// Uninstall-time association cleanup: delete the .clingfyproj default value
// only if it still equals this channel's ProgId. If another channel (or any
// other app) owns the extension by now, leave it alone.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CurrentProgId: string;
begin
  if CurUninstallStep = usUninstall then
  begin
    if RegQueryStringValue(HKA, 'Software\Classes\.clingfyproj', '', CurrentProgId) and
       (CurrentProgId = '{#MyProgId}') then
      RegDeleteValue(HKA, 'Software\Classes\.clingfyproj', '');
  end;
end;
