#ifndef AppVersion
  #error AppVersion must be provided
#endif
#ifndef SourceDir
  #error SourceDir must be provided
#endif
#ifndef OutputDir
  #error OutputDir must be provided
#endif
#ifndef OutputName
  #define OutputName "velocitty-setup"
#endif

[Setup]
AppId={{E937A98D-726D-423A-9251-EFBBC34577C1}
AppName=Velocitty
AppVersion={#AppVersion}
AppPublisher=Vasco Alves
AppPublisherURL=https://github.com/valvesky/velocitty
DefaultDirName={localappdata}\Programs\Velocitty
DefaultGroupName=Velocitty
UninstallDisplayIcon={app}\velocitty.exe
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\assets\icon.ico
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\velocitty.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\example.config.toml"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Velocitty"; Filename: "{app}\velocitty.exe"; WorkingDir: "{%USERPROFILE}"
Name: "{autodesktop}\Velocitty"; Filename: "{app}\velocitty.exe"; WorkingDir: "{%USERPROFILE}"; Tasks: desktopicon

[Run]
Filename: "{app}\velocitty.exe"; Description: "Launch Velocitty"; Flags: nowait postinstall skipifsilent
