; Bellow Flo for Windows: a per-user installer. No administrator rights, no
; UAC prompt; installs to %LOCALAPPDATA%\Programs\Bellow Flo. The user's data
; (%LOCALAPPDATA%\Bellow Flo: settings, dictionary, logs) is never touched,
; so an uninstall and reinstall keeps it.
;
; Built by windows\package.ps1, which passes /DAppVersion and /DSourceDir.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\dist\windows\app"
#endif

[Setup]
AppId={{6F1C9C4E-3B7A-4E0A-9D52-2C7B8A1E5B10}
AppName=Bellow Flo
AppVersion={#AppVersion}
AppVerName=Bellow Flo {#AppVersion}
AppPublisher=Bellow Flo
AppPublisherURL=https://github.com/ArranStrange/talk-talk-talk
DefaultDirName={localappdata}\Programs\Bellow Flo
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\..\dist
OutputBaseFilename=BellowFlo-{#AppVersion}-windows-x64-setup
SetupIconFile=..\BellowFlo\BellowFlo.ico
UninstallDisplayIcon={app}\BellowFlo.exe
UninstallDisplayName=Bellow Flo
Compression=lzma2/max
SolidCompression=yes
LZMANumBlockThreads=4
WizardStyle=modern
; The app and its engine are stopped by the code below, not by the Restart
; Manager, which would also offer to close unrelated Python processes.
CloseApplications=no

[Tasks]
Name: "startup"; Description: "Start Bellow Flo when I sign in"; GroupDescription: "Options:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{userprograms}\Bellow Flo"; Filename: "{app}\BellowFlo.exe"

[Registry]
; The same value the app's own "Start at login" menu item writes.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; \
  ValueName: "Bellow Flo"; ValueData: """{app}\BellowFlo.exe"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\BellowFlo.exe"; Description: "Start Bellow Flo now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Bytecode Python may write beside the engine at run time.
Type: filesandordirs; Name: "{app}\engine"

[Code]
// Stop a running copy before files are replaced or removed: the tray app by
// name, and the speech engine by asking it to quit (killing every
// python.exe would take unrelated programs down with it).
procedure StopBellowFlo();
var
  Code: Integer;
  Py: String;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM BellowFlo.exe', '', SW_HIDE,
       ewWaitUntilTerminated, Code);
  Py := ExpandConstant('{app}\engine\runtime\python.exe');
  if FileExists(Py) then
    Exec(Py, '-X utf8 "' + ExpandConstant('{app}\engine\ktts') + '" quit', '', SW_HIDE,
         ewWaitUntilTerminated, Code);
  Sleep(500);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopBellowFlo();
  Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    StopBellowFlo();
end;
