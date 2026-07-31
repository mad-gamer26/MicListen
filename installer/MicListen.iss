#define AppName "MicListen"
#ifndef AppVersion
#define AppVersion "0.5.4"
#endif
#define AppPublisher "mad-gamer26"
#define AppExeName "MicListen.exe"

[Setup]
AppId={{2D1AA52B-0567-4A1B-B592-C35E52BCE82F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
OutputDir=..\dist\installer
OutputBaseFilename=MicListen-{#AppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
LicenseFile=..\LICENSE
CloseApplications=no
RestartApplications=no
ChangesEnvironment=yes

[Files]
Source: "..\dist\MicListen.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--background"; WorkingDir: "{app}"

[Code]
const
  UserEnvironmentKey = 'Environment';
  PathValueName = 'Path';
  MicListenRegistryKey = 'Software\MicListen';
  PathMarkerValueName = 'PathEntryAdded';

function NormalizePathEntry(Value: string): string;
begin
  Result := Trim(Value);
  if (Length(Result) >= 2) and (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
  begin
    Delete(Result, Length(Result), 1);
    Delete(Result, 1, 1);
  end;
  while (Length(Result) > 3) and
        ((Result[Length(Result)] = '\') or (Result[Length(Result)] = '/')) do
    Delete(Result, Length(Result), 1);
  Result := Lowercase(Result);
end;

function NextPathEntry(var Remaining: string): string;
var
  Separator: Integer;
begin
  Separator := Pos(';', Remaining);
  if Separator = 0 then
  begin
    Result := Remaining;
    Remaining := '';
  end
  else
  begin
    Result := Copy(Remaining, 1, Separator - 1);
    Delete(Remaining, 1, Separator);
  end;
end;

function PathContains(CurrentPath, Directory: string): Boolean;
var
  Entry: string;
  Target: string;
begin
  Result := False;
  Target := NormalizePathEntry(Directory);
  while CurrentPath <> '' do
  begin
    Entry := NextPathEntry(CurrentPath);
    if NormalizePathEntry(Entry) = Target then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure AddInstallDirectoryToPath;
var
  CurrentPath: string;
  InstallDirectory: string;
begin
  InstallDirectory := ExpandConstant('{app}');
  if not RegQueryStringValue(HKCU, UserEnvironmentKey, PathValueName,
    CurrentPath) then
    CurrentPath := '';

  if PathContains(CurrentPath, InstallDirectory) then
    Exit;

  if (CurrentPath <> '') and (CurrentPath[Length(CurrentPath)] <> ';') then
    CurrentPath := CurrentPath + ';';
  CurrentPath := CurrentPath + InstallDirectory;
  if RegWriteExpandStringValue(HKCU, UserEnvironmentKey, PathValueName,
    CurrentPath) then
    RegWriteDWordValue(HKCU, MicListenRegistryKey, PathMarkerValueName, 1);
end;

procedure RemoveInstallDirectoryFromPath;
var
  CurrentPath: string;
  Entry: string;
  NewPath: string;
  Target: string;
  PathMarker: Cardinal;
  KeptAnyEntry: Boolean;
begin
  if not RegQueryDWordValue(HKCU, MicListenRegistryKey,
    PathMarkerValueName, PathMarker) or (PathMarker <> 1) then
    Exit;

  if not RegQueryStringValue(HKCU, UserEnvironmentKey, PathValueName,
    CurrentPath) then
    CurrentPath := '';

  Target := NormalizePathEntry(ExpandConstant('{app}'));
  NewPath := '';
  KeptAnyEntry := False;
  while CurrentPath <> '' do
  begin
    Entry := NextPathEntry(CurrentPath);
    if NormalizePathEntry(Entry) <> Target then
    begin
      if KeptAnyEntry then
        NewPath := NewPath + ';';
      NewPath := NewPath + Entry;
      KeptAnyEntry := True;
    end;
  end;

  if not KeptAnyEntry then
    RegDeleteValue(HKCU, UserEnvironmentKey, PathValueName)
  else
    RegWriteExpandStringValue(HKCU, UserEnvironmentKey, PathValueName,
      NewPath);

  RegDeleteValue(HKCU, MicListenRegistryKey, PathMarkerValueName);
  RegDeleteKeyIfEmpty(HKCU, MicListenRegistryKey);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    AddInstallDirectoryToPath;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveInstallDirectoryFromPath;
end;
