param(
  [Parameter(Mandatory = $true)][string]$Mihomo,
  [string]$OutputDirectory = 'windows-tun-experiment'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path

function Save-NetworkState([string]$Name) {
  $state = [ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    adapters = @(Get-NetAdapter | Select-Object Name, InterfaceDescription, InterfaceIndex, Status, MacAddress)
    addresses = @(Get-NetIPAddress | Select-Object InterfaceIndex, AddressFamily, IPAddress, PrefixLength)
    routes = @(Get-NetRoute | Select-Object InterfaceIndex, AddressFamily, DestinationPrefix, NextHop, RouteMetric, PolicyStore)
    dns = @(Get-DnsClientServerAddress | Select-Object InterfaceIndex, AddressFamily, ServerAddresses)
  }
  $state | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory "$Name.json")
}

function Send-CoreAction([string]$Method, [object]$Data) {
  $id = [Guid]::NewGuid().ToString('N')
  $request = @{ id = $id; method = $Method; data = $Data } | ConvertTo-Json -Depth 15 -Compress
  $script:writer.WriteLine($request)
  $script:writer.Flush()
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline) {
    $lineTask = $script:reader.ReadLineAsync()
    if (-not $lineTask.Wait([TimeSpan]::FromSeconds(20))) { throw "$Method response timed out" }
    $line = $lineTask.Result
    if ($null -eq $line) { throw "$Method disconnected" }
    $response = $line | ConvertFrom-Json
    if ($response.id -eq $id) {
      $response | ConvertTo-Json -Depth 8 | Add-Content -Encoding utf8 (Join-Path $OutputDirectory 'actions.jsonl')
      if ($response.code -ne 0) { throw "$Method failed: $line" }
      return $response.data
    }
  }
  throw "$Method response timed out"
}

function Start-ExperimentCore([bool]$AutoRoute) {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $process = Start-Process -FilePath $Mihomo -ArgumentList "$port" -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $OutputDirectory 'mihomo.stdout.log') `
    -RedirectStandardError (Join-Path $OutputDirectory 'mihomo.stderr.log')
  try {
    $accept = $listener.AcceptTcpClientAsync()
    if (-not $accept.Wait([TimeSpan]::FromSeconds(20))) { throw 'mihomo did not connect to the control socket' }
    $script:client = $accept.Result
    $stream = $script:client.GetStream()
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $script:reader = [IO.StreamReader]::new($stream, $utf8NoBom)
    $script:writer = [IO.StreamWriter]::new($stream, $utf8NoBom)
    $mihomoHome = Join-Path $OutputDirectory 'mihomo-home'
    New-Item -ItemType Directory -Force $mihomoHome | Out-Null
    $initialized = Send-CoreAction 'initClash' (@{ 'home-dir' = $mihomoHome; version = 1 } | ConvertTo-Json -Compress)
    if ($initialized -ne $true) { throw 'mihomo initialization failed' }
    $config = @{
      'mixed-port' = 0
      mode = 'direct'
      proxies = @()
      rules = @('MATCH,DIRECT')
      tun = @{
        enable = $true
        stack = 'system'
        device = 'FlClashMTest'
        mtu = 1500
        'auto-route' = $AutoRoute
        'auto-detect-interface' = $true
        'route-address' = @('198.18.0.0/24')
      }
    }
    $setup = @{ config = $config; 'selected-map' = @{}; 'test-url' = '' } | ConvertTo-Json -Depth 15 -Compress
    $setupResult = Send-CoreAction 'setupConfig' $setup
    if ($setupResult -ne '') { throw "mihomo setup failed: $setupResult" }
    $started = Send-CoreAction 'startListener' $null
    if ($started -ne $true) { throw 'mihomo listener did not start' }
    return $process
  } catch {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw
  } finally {
    $listener.Stop()
  }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
@{ user = $identity.Name; isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } |
  ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'identity.json')

Save-NetworkState 'before'
$core = $null
try {
  # The only route mihomo may add is a reserved benchmark prefix. Never
  # request a default route on a GitHub runner: it would break the job's link.
  $core = Start-ExperimentCore $true
  Start-Sleep -Seconds 4
  Save-NetworkState 'running'
  $stopped = Send-CoreAction 'stopListener' $null
  if ($stopped -ne $true) { throw 'mihomo listener did not stop' }
  Start-Sleep -Seconds 3
  Save-NetworkState 'stopped'
  $started = Send-CoreAction 'startListener' $null
  if ($started -ne $true) { throw 'mihomo listener did not restart' }
  Start-Sleep -Seconds 3
  Save-NetworkState 'before-kill'
  Stop-Process -Id $core.Id -Force
  $core.WaitForExit(10000) | Out-Null
  $core = $null
  Start-Sleep -Seconds 4
  Save-NetworkState 'after-kill'
} catch {
  $_ | Out-String | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'error.txt')
  throw
} finally {
  if ($null -ne $core -and -not $core.HasExited) { Stop-Process -Id $core.Id -Force }
  if ($null -ne $script:client) { $script:client.Dispose() }
  Save-NetworkState 'final'
}
