[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}
UninstallDisplayIcon={uninstallexe}
ChangesAssociations=yes
CloseApplications=no
RestartApplications=no
; Update mode settings
UsePreviousAppDir=no
UsePreviousGroup=yes
UsePreviousTasks=yes

[Code]
const
  SHCNE_ASSOCCHANGED = $08000000;
  SHCNF_IDLIST = $0000;

var
  IsUpgrade: Boolean;
  PreviousVersion: String;
  PreviousBundleBackup: String;
  FreshInstallDirectoryCreated: Boolean;
  InstallStarted: Boolean;
  InstallSucceeded: Boolean;

const
  HelperServiceName = 'app.flclashm.client.helper';
  HelperRelativePath = 'runtimes\windows\x86_64\app.flclashm.client.helper.exe';

function IsFromApp(): Boolean;
begin
  Result := ExpandConstant('{param:FROMAPP|0}') = '1';
end;

procedure WriteInstallResult(const Status: String);
begin
  { HKLM is administrator-owned but readable by the interactive user. A
    caller-controlled ProgramData junction must not redirect an elevated file
    write to an arbitrary destination. }
  if not RegWriteStringValue(HKEY_LOCAL_MACHINE_64, 'Software\FlClashM',
    'InstallResult', '{{APP_VERSION}}:' + Status + ':' +
    GetDateTimeString('yyyymmddhhnnss', '-', ':')) then
    Log('Не удалось записать результат установки FlClashM в реестр.');
end;

procedure SHChangeNotify(wEventId: Integer; uFlags: Integer; dwItem1: Integer; dwItem2: Integer); external 'SHChangeNotify@shell32.dll stdcall';

function IsProcessRunning(const ProcessName: String): Boolean;
var
  ResultCode: Integer;
begin
  { Check all interactive sessions. The installer must never terminate another
    user's GUI before it has restored that user's proxy and tunnel. }
  Result := not Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -Command "if (Get-Process -Name ' + ProcessName + ' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0);
end;

function WaitForGracefulExit(): Boolean;
var
  Attempt: Integer;
begin
  for Attempt := 1 to 30 do
  begin
    if not IsProcessRunning('FlClashM') and
       not IsProcessRunning('proxy_watchdog') then
    begin
      Result := True;
      exit;
    end;
    Sleep(1000);
  end;
  Result := False;
end;

procedure CopyBundle(const Source, Destination: String);
var
  ResultCode: Integer;
begin
  ForceDirectories(Destination);
  if not Exec(
    ExpandConstant('{sys}\robocopy.exe'),
    '"' + Source + '" "' + Destination + '" /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode >= 8) then
    RaiseException('Не удалось сохранить или восстановить предыдущую установку. Код: ' + IntToStr(ResultCode));
end;

procedure EnforceProtectedInstallAcl;
var
  ResultCode: Integer;
begin
  { Reset explicit ACLs on the fixed Program Files directory and children.
    They inherit Program Files permissions: users can read/run, while SYSTEM
    and Administrators can write. A previous user-writable ACL must not turn
    the helper's trusted executable path into a privilege boundary bypass. }
  if not Exec(ExpandConstant('{sys}\icacls.exe'),
    '"' + ExpandConstant('{app}') + '" /reset /T', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    RaiseException('Не удалось защитить права каталога FlClashM. Код: ' + IntToStr(ResultCode));
end;

procedure StopAndRemoveHelperService;
var
  ResultCode: Integer;
  Attempt: Integer;
begin
  { The GUI has already completed network teardown. Service stop is still
    required to release its binary and any privileged child. }
  Exec(ExpandConstant('{sys}\sc.exe'), 'query "' + HelperServiceName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode = 1060 then
    exit;
  if ResultCode <> 0 then
    RaiseException('Не удалось проверить службу FlClashM. Код: ' + IntToStr(ResultCode));
  Exec(ExpandConstant('{sys}\sc.exe'), 'stop "' + HelperServiceName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if (ResultCode <> 0) and (ResultCode <> 1062) then
    RaiseException('Не удалось остановить службу FlClashM. Код: ' + IntToStr(ResultCode));
  if not Exec(ExpandConstant('{sys}\sc.exe'), 'delete "' + HelperServiceName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    RaiseException('Не удалось удалить службу FlClashM. Код: ' + IntToStr(ResultCode));
  for Attempt := 1 to 15 do
  begin
    Sleep(1000);
    Exec(ExpandConstant('{sys}\sc.exe'), 'query "' + HelperServiceName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if ResultCode = 1060 then
      exit;
  end;
  RaiseException('Служба FlClashM не завершилась за 15 секунд.');
end;

procedure InstallAndStartHelperService;
var
  ResultCode: Integer;
  ServiceBinary: String;
  Attempt: Integer;
begin
  ServiceBinary := ExpandConstant('{app}\' + HelperRelativePath);
  if not FileExists(ExpandConstant('{app}\FlClashM.exe')) or
     not FileExists(ExpandConstant('{app}\runtimes\windows\x86_64\mihomo.exe')) or
     not FileExists(ServiceBinary) then
    RaiseException('В установленном пакете отсутствуют обязательные файлы FlClashM.');
  if not Exec(
    ExpandConstant('{sys}\sc.exe'),
    'create "' + HelperServiceName + '" binPath= "\"' + ServiceBinary + '\"" start= auto',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    RaiseException('Не удалось установить системную службу FlClashM. Код: ' + IntToStr(ResultCode));
  if not Exec(
    ExpandConstant('{sys}\sc.exe'),
    'start "' + HelperServiceName + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    RaiseException('Не удалось запустить системную службу FlClashM. Код: ' + IntToStr(ResultCode));
  for Attempt := 1 to 10 do
  begin
    if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -NonInteractive -Command "if ((Get-Service -Name ''' + HelperServiceName + ''' -ErrorAction SilentlyContinue).Status -eq ''Running'') { exit 0 } else { exit 1 }"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
      exit;
    Sleep(1000);
  end;
  RaiseException('Служба FlClashM не перешла в рабочее состояние.');
end;

procedure RestorePreviousHelperService;
begin
  if (PreviousBundleBackup = '') or not DirExists(PreviousBundleBackup) then
    exit;
  if FileExists(ExpandConstant('{app}\' + HelperRelativePath)) then
    InstallAndStartHelperService;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  { The helper authenticates the installed GUI path. Never let /DIR or a
    previous per-user installation move that trusted executable into a
    user-writable directory. }
  if CompareText(ExpandFileName(ExpandConstant('{app}')),
    ExpandFileName(ExpandConstant('{autopf}\FlClashM'))) <> 0 then
  begin
    Result := 'FlClashM должен быть установлен в защищённый каталог Program Files. Удалите старую установку в другом каталоге и повторите установку.';
    exit;
  end;
  if IsUpgrade and not FileExists(ExpandConstant('{app}\FlClashM.exe')) then
  begin
    Result := 'Предыдущая установка FlClashM находится в другом каталоге. Сначала удалите её, затем установите новую версию в Program Files.';
    exit;
  end;
  if not WaitForGracefulExit() then
    Result := 'FlClashM ещё работает или восстанавливает системный прокси. Закройте приложение через меню значка в области уведомлений и повторите установку.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := not IsProcessRunning('FlClashM') and
            not IsProcessRunning('proxy_watchdog');
  if not Result then
    MsgBox('Сначала закройте FlClashM через меню значка в области уведомлений, затем повторите удаление.', mbError, MB_OK);
end;

procedure RelaunchAppAsOriginalUser();
var
  ResultCode: Integer;
begin
  if not FileExists(ExpandConstant('{app}\FlClashM.exe')) then
    exit;
  try
    if not ExecAsOriginalUser(ExpandConstant('{app}\FlClashM.exe'), '', '',
      SW_SHOWNORMAL, ewNoWait, ResultCode) then
      Log('Не удалось повторно открыть FlClashM. Код: ' + IntToStr(ResultCode));
  except
    Log('Не удалось повторно открыть FlClashM с правами исходного пользователя.');
  end;
end;

procedure DeinitializeSetup();
begin
  if InstallSucceeded then
    exit;
  if not InstallStarted then
  begin
    { An app-initiated setup may fail before touching files (for example,
      another user's GUI is still open). Restore the old GUI in that case. }
    if IsFromApp() then
    begin
      WriteInstallResult('failed');
      RelaunchAppAsOriginalUser();
    end;
    exit;
  end;
  try
    StopAndRemoveHelperService;
    if PreviousBundleBackup <> '' then
    begin
      CopyBundle(PreviousBundleBackup, ExpandConstant('{app}'));
      RestorePreviousHelperService;
    end;
    if FreshInstallDirectoryCreated and
       (PreviousBundleBackup = '') and
       DirExists(ExpandConstant('{app}')) and
       not DelTree(ExpandConstant('{app}'), True, True, True) then
      RaiseException('Не удалось удалить неполную новую установку FlClashM.');
    WriteInstallResult('failed');
    { The old GUI must read the failure marker after it has been written. }
    if (PreviousBundleBackup <> '') and IsFromApp() then
      RelaunchAppAsOriginalUser();
  except
    WriteInstallResult('rollback-failed');
    MsgBox('Обновление прервалось, и восстановить прежнюю версию автоматически не удалось. Повторите установку предыдущего пакета.', mbError, MB_OK);
  end;
end;

function IsAppInstalled(): Boolean;
var
  UninstallKey: String;
begin
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{APP_ID}}_is1';
  Result := RegKeyExists(HKEY_LOCAL_MACHINE, UninstallKey) or 
            RegKeyExists(HKEY_CURRENT_USER, UninstallKey);
end;

function IsUpgradeInstallation(): Boolean;
begin
  Result := IsUpgrade;
end;

function GetInstalledVersion(): String;
var
  UninstallKey: String;
  Version: String;
begin
  Result := '';
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{APP_ID}}_is1';
  
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, UninstallKey, 'DisplayVersion', Version) then
    Result := Version
  else if RegQueryStringValue(HKEY_CURRENT_USER, UninstallKey, 'DisplayVersion', Version) then
    Result := Version;
end;

function InitializeSetup(): Boolean;
begin
  // Check if app is already installed
  IsUpgrade := IsAppInstalled();
  if IsUpgrade then
    PreviousVersion := GetInstalledVersion();
  
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    FreshInstallDirectoryCreated := not IsUpgrade and
      not DirExists(ExpandConstant('{app}'));
    if DirExists(ExpandConstant('{app}')) then
    begin
      PreviousBundleBackup := ExpandConstant('{tmp}\flclashm-previous-bundle');
      CopyBundle(ExpandConstant('{app}'), PreviousBundleBackup);
    end;
    InstallStarted := True;
    StopAndRemoveHelperService;
  end
  else if CurStep = ssPostInstall then
  begin
    EnforceProtectedInstallAcl;
    InstallAndStartHelperService;
  end
  else if CurStep = ssDone then
  begin
    InstallSucceeded := True;
    WriteInstallResult('success');
    if IsFromApp() then
      RelaunchAppAsOriginalUser();
  end;
end;

procedure InitializeWizard();
begin
  if IsUpgrade then
  begin
    WizardForm.Caption := '{{DISPLAY_NAME}} - Обновление';
    if PreviousVersion <> '' then
      WizardForm.WelcomeLabel2.Caption := 
        'Обнаружена установленная версия ' + PreviousVersion + '.' + #13#10 + #13#10 +
        'Программа установит версию {{APP_VERSION}}.' + #13#10 + #13#10 +
        'Нажмите «Далее», чтобы продолжить обновление, или «Отмена», чтобы выйти.'
    else
      WizardForm.WelcomeLabel2.Caption := 
        'Обнаружена установленная версия программы.' + #13#10 + #13#10 +
        'Программа установит версию {{APP_VERSION}}.' + #13#10 + #13#10 +
        'Нажмите «Далее», чтобы продолжить обновление, или «Отмена», чтобы выйти.';
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  if IsUpgrade then
  begin
    Result := 'Обновление' + NewLine;
    if PreviousVersion <> '' then
      Result := Result + 'Текущая версия: ' + PreviousVersion + NewLine;
    Result := Result + 'Новая версия: {{APP_VERSION}}' + NewLine + NewLine;
  end
  else
    Result := 'Новая установка' + NewLine + NewLine;
    
  if MemoDirInfo <> '' then
    Result := Result + MemoDirInfo + NewLine + NewLine;
  if MemoGroupInfo <> '' then
    Result := Result + MemoGroupInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then
    Result := Result + MemoTasksInfo + NewLine;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  case CurUninstallStep of
    usUninstall:
    begin
      StopAndRemoveHelperService;
    end;

    usPostUninstall:
    begin
      RegDeleteValue(HKEY_LOCAL_MACHINE_64, 'Software\FlClashM', 'InstallResult');
      if DirExists(ExpandConstant('{userappdata}\app.flclashm.client')) then
      begin
        if MsgBox('Удалить пользовательские данные программы?', mbConfirmation, MB_YESNO) = IDYES then
        begin
          DelTree(ExpandConstant('{userappdata}\app.flclashm.client'), True, True, True);
        end;
      end;
    end;
  end;
end;
[Languages]
{% for locale in LOCALES %}
{% if locale.lang == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale.lang == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale.lang == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale.lang == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale.lang == 'zh' %}
Name: "chineseSimplified"; MessagesFile: {% if locale.file %}{{ locale.file }}{% else %}"compiler:Languages\\ChineseSimplified.isl"{% endif %}
{% endif %}
{% if locale.lang == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale.lang == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale.lang == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale.lang == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale.lang == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale.lang == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale.lang == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale.lang == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale.lang == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale.lang == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale.lang == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale.lang == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale.lang == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale.lang == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale.lang == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale.lang == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale.lang == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale.lang == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale.lang == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale.lang == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce; Check: not IsUpgradeInstallation
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: runasoriginaluser nowait postinstall skipifsilent; Check: not IsFromApp
