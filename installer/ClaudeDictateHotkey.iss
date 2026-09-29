; Per-user installer (no admin prompt). Built by build.ps1, which passes /DAppVersion.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Claude Dictate Hotkey"
#define AppExe "ClaudeDictateHotkey.exe"

[Setup]
; AppId identifies the app for upgrades/uninstall; never change it.
AppId={{C3A4C0AB-6E56-4C58-83D5-BEAE19733186}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=AweDev
AppPublisherURL=https://github.com/AweGuider/Claude-Dictate-Hotkey
DefaultDirName={autopf}\ClaudeDictateHotkey
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=ClaudeDictateHotkey-{#AppVersion}-setup
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#AppExe}
LicenseFile=..\LICENSE
WizardStyle=modern
CloseApplications=force

[Tasks]
Name: "startup"; Description: "Start with Windows (stays hidden while Claude is closed)"; Flags: unchecked

[Files]
Source: "..\dist\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autoprograms}\{#AppName} Settings"; Filename: "{app}\{#AppExe}"; Parameters: "/settings"
; Same path and arguments the in-app "Start with Windows" checkbox manages.
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Parameters: "/startup"; WorkingDir: "{app}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "StopApp"

[UninstallDelete]
; The in-app checkbox can create this shortcut after install.
Type: files; Name: "{userstartup}\{#AppName}.lnk"
