param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$FailingInstaller,
  [string]$OutputDirectory = 'windows-desktop-evidence'
)
$ErrorActionPreference = 'Stop'
$serviceName = 'app.flclashm.client.helper'
$appRoot = Join-Path $env:ProgramFiles 'FlClashM'
$gui = Join-Path $appRoot 'FlClashM.exe'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
$probeName = 'FlClashMDesktopProbe'
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
  if ($null -ne $Credential) { $parameters.Credential = $Credential; $parameters.LoadUserProfile = $true }
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

try {
  Run-Setup (Resolve-Path $Installer).Path $true
  if ((Get-Service $serviceName).Status -ne 'Running') { throw 'Service did not start after installation.' }
  $events.Add('installed')
  $null = Run-AppCheck 'administrator-lifecycle' $null $false
  $password = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N') + 'aA1!') -AsPlainText -Force
  New-LocalUser -Name $probeName -Password $password -AccountNeverExpires | Out-Null
  icacls.exe $output /grant "${probeName}:(OI)(CI)M" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not grant evidence directory access.' }
  $credential = [PSCredential]::new("$env:COMPUTERNAME\$probeName", $password)
  $null = Run-AppCheck 'ordinary-user-lifecycle' $credential $false

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
  Run-Setup (Resolve-Path $FailingInstaller).Path $false
  if ((Get-FileHash $gui -Algorithm SHA256).Hash -ne $oldHash) { throw 'Rollback did not restore the original GUI.' }
  if (Test-Path (Join-Path $appRoot 'rollback-new-file.test')) { throw 'Rollback left a new package file behind.' }
  if ((Get-Service $serviceName).Status -ne 'Running') { throw 'Rollback did not restore the helper service.' }
  $events.Add('failed-install-rolled-back')
  $null = Run-AppCheck 'after-rollback' $credential $false
  Run-Setup (Resolve-Path $Installer).Path $true
  if (-not (Test-Path $marker)) { throw 'Upgrade deleted user data.' }
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
  Get-Process FlClashM -ErrorAction SilentlyContinue | Stop-Process -Force
  Stop-Service $serviceName -ErrorAction SilentlyContinue
  sc.exe delete $serviceName | Out-Null
  Remove-LocalUser -Name $probeName -ErrorAction SilentlyContinue
}
