[CmdletBinding(DefaultParameterSetName = 'Lifecycle')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Lifecycle')][string]$Installer,
  [Parameter(Mandatory = $true, ParameterSetName = 'Lifecycle')][string]$FailingInstaller,
  [Parameter(Mandatory = $true, ParameterSetName = 'Profile')][switch]$ProfileOnly,
  [string]$OutputDirectory = 'windows-desktop-evidence'
)
$ErrorActionPreference = 'Stop'
$serviceName = 'app.flclashm.client.helper'
$appRoot = Join-Path $env:ProgramFiles 'FlClashM'
$gui = Join-Path $appRoot 'FlClashM.exe'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
$probeName = 'FlClashMDesktopProbe'
$probeEnvironment = $null
$events = [Collections.Generic.List[string]]::new()

function Run-Setup([string]$File, [bool]$ExpectSuccess) {
  $process = Start-Process -FilePath $File -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$output\setup-$($events.Count).log`"") -PassThru
  if (-not $process.WaitForExit(60000)) { Stop-Process -Id $process.Id -Force; throw 'Setup exceeded 60 seconds.' }
  if ($ExpectSuccess -ne ($process.ExitCode -eq 0)) { throw "Unexpected setup exit: $($process.ExitCode)" }
}

function Require-CleanNetwork {
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $active = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'FlClashM' -and $_.Status -eq 'Up' })
    $children = @(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" | Where-Object { $_.ExecutablePath -like "$appRoot\*" })
    $routes = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq 'FlClashM' -and $_.DestinationPrefix -eq '198.18.0.0/24' })
    if ($active.Count -eq 0 -and $children.Count -eq 0 -and $routes.Count -eq 0) { return }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  Get-NetAdapter -IncludeHidden | Format-List | Out-File "$output\adapters-failed.txt"
  Get-NetRoute | Format-List | Out-File "$output\routes-failed.txt"
  throw 'Installed core or TUN routes remained after cleanup.'
}

function Run-AppCheck([string]$Name, [PSCredential]$Credential, [bool]$Hold) {
  $resultFile = Join-Path $output "$Name.json"
  $arguments = @('--windows-runtime-check', "`"$resultFile`"")
  if ($Hold) { $arguments += '--hold' }
  $parameters = @{ FilePath=$gui; ArgumentList=$arguments; PassThru=$true }
  if ($null -ne $Credential) {
    $parameters.Credential = $Credential
    $parameters.LoadUserProfile = $true
    $parameters.Environment = $probeEnvironment
  }
  $process = Start-Process @parameters
  $deadline = (Get-Date).AddSeconds(90)
  while (-not (Test-Path $resultFile)) {
    if ($process.HasExited -or (Get-Date) -ge $deadline) {
      if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
      throw "GUI did not finish $Name."
    }
    Start-Sleep -Milliseconds 200
  }
  $result = Get-Content $resultFile -Raw | ConvertFrom-Json
  if ($result.success -ne $true) {
    # The caller assigns this function's return to $null; use the host stream
    # for diagnostics so it cannot discard the failure details.
    Get-Content $resultFile -Raw | Write-Host
    Get-CimInstance Win32_Service -Filter "Name='$serviceName'" | Select-Object State, ProcessId, StartName, PathName | Format-List | Out-String | Write-Host
    throw "GUI $Name failed: $($result.error)"
  }
  if (-not $Hold) {
    if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw "GUI $Name did not exit successfully." }
    Require-CleanNetwork
    $events.Add($Name)
    Write-Host "Passed installed GUI check: $Name"
  }
  return $process
}

function Initialize-OrdinaryUser {
  $password = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N') + 'aA1!') -AsPlainText -Force
  $user = New-LocalUser -Name $probeName -Password $password -AccountNeverExpires
  $users = Get-LocalGroup -SID 'S-1-5-32-545'
  if (-not (@(Get-LocalGroupMember -Group $users).SID -contains $user.SID)) {
    Add-LocalGroupMember -Group $users -Member $user
  }
  icacls.exe $output /grant "${probeName}:(OI)(CI)M" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not grant evidence directory access.' }
  $credential = [PSCredential]::new("$env:COMPUTERNAME\$probeName", $password)
  # LoadUserProfile loads the registry hive but does not perform a first shell
  # logon. Create the known AppData folders under the probe's own token, then
  # launch its GUI with that user's environment rather than runneradmin's.
  $profileScript = Join-Path $output 'initialize-probe-profile.ps1'
  $profileFile = Join-Path $output 'probe-profile.json'
  @'
param([string]$OutputFile)
$ErrorActionPreference = 'Stop'
try {
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Probe must be an ordinary user.'
}
$create = [Environment+SpecialFolderOption]::Create
$profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile, $create)
if (-not $profile) { throw 'Probe profile directory could not be located.' }
# The secondary logon inherits runneradmin's APPDATA/LOCALAPPDATA values.
# Derive these fixture folders from the actual token's profile, then pass
# them as environment overrides when launching the ordinary-user GUI.
$roaming = Join-Path $profile 'AppData\Roaming'
$local = Join-Path $profile 'AppData\Local'
New-Item -ItemType Directory -Force $roaming, $local | Out-Null
$temporary = Join-Path $local 'Temp'
New-Item -ItemType Directory -Force $temporary | Out-Null
@{ USERPROFILE=$profile; APPDATA=$roaming; LOCALAPPDATA=$local; TEMP=$temporary; TMP=$temporary } |
  ConvertTo-Json | Set-Content -Encoding utf8 $OutputFile
} catch {
  @{ error=($_ | Out-String); identity=$identity.Name; profile=$profile; roaming=$roaming; local=$local } |
    ConvertTo-Json | Set-Content -Encoding utf8 $OutputFile
  exit 1
}
'@ | Set-Content -Encoding utf8 $profileScript
  $initialize = Start-Process -FilePath (Get-Command pwsh).Source -Credential $credential -LoadUserProfile -PassThru `
    -ArgumentList @('-NoProfile', '-File', "`"$profileScript`"", '-OutputFile', "`"$profileFile`"")
  if (-not $initialize.WaitForExit(30000)) { Stop-Process -Id $initialize.Id -Force; throw 'Probe profile initialization timed out.' }
  if ($initialize.ExitCode -ne 0 -or -not (Test-Path $profileFile)) {
    if (Test-Path $profileFile) { Get-Content $profileFile -Raw | Write-Host }
    throw 'Probe profile initialization failed.'
  }
  $script:probeEnvironment = Get-Content $profileFile -Raw | ConvertFrom-Json -AsHashtable
  Write-Host 'Initialized the ordinary-user profile and its AppData folders.'
  return $credential
}

function Require-ProtectedCache([PSCredential]$Credential) {
  $data = Join-Path $appRoot 'service-data'
  $cache = Get-ChildItem -LiteralPath $data -Recurse -File | Select-Object -First 1
  if ($null -eq $cache) { throw 'The runtime did not create a service cache file.' }
  $scriptFile = Join-Path $output 'verify-protected-cache.ps1'
  @'
param([string]$Directory, [string]$CacheFile)
$ErrorActionPreference = 'Stop'
try {
  [IO.Directory]::GetFileSystemEntries($Directory) | Out-Null
  throw 'Ordinary user could list the service cache.'
} catch [UnauthorizedAccessException] {}
try {
  $stream = [IO.File]::OpenRead($CacheFile)
  $stream.Dispose()
  throw 'Ordinary user could read a service cache file.'
} catch [UnauthorizedAccessException] {}
'@ | Set-Content -Encoding utf8 $scriptFile
  $check = Start-Process -FilePath (Get-Command pwsh).Source -Credential $Credential -LoadUserProfile -PassThru `
    -ArgumentList @('-NoProfile', '-File', "`"$scriptFile`"", '-Directory', "`"$data`"", '-CacheFile', "`"$($cache.FullName)`"")
  if (-not $check.WaitForExit(10000)) { Stop-Process -Id $check.Id -Force; throw 'Cache access check timed out.' }
  if ($check.ExitCode -ne 0) { throw 'Service cache was not protected from the ordinary user.' }
  Write-Host 'Ordinary user cannot list or read the protected service cache.'
}

try {
  if ($ProfileOnly) {
    $null = Initialize-OrdinaryUser
    return
  }
  Run-Setup (Resolve-Path $Installer).Path $true
  if ((Get-Service $serviceName).Status -ne 'Running') { throw 'Service did not start after installation.' }
  $events.Add('installed')
  $null = Run-AppCheck 'administrator-lifecycle' $null $false
  $credential = Initialize-OrdinaryUser
  $null = Run-AppCheck 'ordinary-user-lifecycle' $credential $false
  Require-ProtectedCache $credential

  $held = Run-AppCheck 'ordinary-user-crash' $credential $true
  # Manual replacement must refuse an active GUI and leave its runtime alive.
  Run-Setup (Resolve-Path $Installer).Path $false
  if ($held.HasExited) { throw 'Refused upgrade unexpectedly stopped the GUI.' }
  Stop-Process -Id $held.Id -Force
  Require-CleanNetwork
  $events.Add('ordinary-user-crash-cleaned')

  $held = Run-AppCheck 'service-stop' $null $true
  Stop-Service $serviceName
  Require-CleanNetwork
  if (-not $held.HasExited) { Stop-Process -Id $held.Id -Force }
  Start-Service $serviceName
  $events.Add('service-stop-cleaned')
  $null = Run-AppCheck 'service-restart' $credential $false

  $dataRoot = Join-Path $env:APPDATA 'makriq-org\FlClashM'
  New-Item -ItemType Directory -Force $dataRoot | Out-Null
  $marker = Join-Path $dataRoot 'windows-e2e-preserved.txt'
  'preserve me' | Set-Content $marker
  $oldHash = (Get-FileHash $gui -Algorithm SHA256).Hash
  $uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\app.flclashm.client_is1'
  $oldVersion = (Get-ItemProperty $uninstallKey).DisplayVersion
  Run-Setup (Resolve-Path $FailingInstaller).Path $false
  if ((Get-FileHash $gui -Algorithm SHA256).Hash -ne $oldHash) { throw 'Rollback did not restore the original GUI.' }
  if (Test-Path (Join-Path $appRoot 'rollback-new-file.test')) { throw 'Rollback left a new package file behind.' }
  if ((Get-Service $serviceName).Status -ne 'Running') { throw 'Rollback did not restore the helper service.' }
  if ((Get-ItemProperty $uninstallKey).DisplayVersion -ne $oldVersion) { throw 'Rollback did not restore the registered version.' }
  $events.Add('failed-install-rolled-back')
  $null = Run-AppCheck 'after-rollback' $credential $false
  Require-ProtectedCache $credential
  Run-Setup (Resolve-Path $Installer).Path $true
  if (-not (Test-Path $marker)) { throw 'Upgrade deleted user data.' }
  Require-ProtectedCache $credential
  $events.Add('upgrade-preserved-data')

  # A process outside the protected GUI image must never get a privileged lease.
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'app.flclashm.client.helper.v1', [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
  try {
    $pipe.Connect(10000)
    $request = [Text.Encoding]::UTF8.GetBytes('{"protocolVersion":1,"installIdentity":"app.flclashm.client","operation":"ping","parameters":{}}')
    $pipe.Write($request,0,$request.Length)
    $buffer = New-Object byte[] 4096
    $readTask = $pipe.ReadAsync($buffer,0,$buffer.Length)
    if (-not $readTask.Wait(10000)) { throw 'Unauthorized IPC response timed out.' }
    $response = [Text.Encoding]::UTF8.GetString($buffer,0,$readTask.Result) | ConvertFrom-Json
    if ($response.state -ne 'failed' -or $response.message -notlike 'Client is not the installed FlClashM application*') { throw 'Helper accepted an unauthorized client.' }
  } finally { $pipe.Dispose() }
  $events.Add('unauthorized-ipc-rejected')
  $uninstall = Join-Path $appRoot 'unins000.exe'
  Run-Setup $uninstall $true
  if (Get-Service $serviceName -ErrorAction SilentlyContinue) { throw 'Service remained after uninstall.' }
  if (-not (Test-Path $marker)) { throw 'Silent uninstall deleted user data.' }
  $events.Add('uninstalled-preserved-data')
  @{ success=$true; checks=$events.ToArray() } | ConvertTo-Json -Depth 5 | Set-Content "$output\summary.json"
} finally {
  if (-not $ProfileOnly) {
    Get-Process FlClashM -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Service $serviceName -ErrorAction SilentlyContinue
    sc.exe delete $serviceName | Out-Null
  }
  Remove-LocalUser -Name $probeName -ErrorAction SilentlyContinue
}
