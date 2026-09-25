param(
  [Parameter(Mandatory = $true)][string]$BundleDirectory,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)

$ErrorActionPreference = 'Stop'
$bundle = (Resolve-Path $BundleDirectory).Path
if (-not (Test-Path (Join-Path $bundle 'runtimes\windows\x86_64\app.flclashm.client.helper.exe'))) {
  throw 'В Windows bundle отсутствует service helper.'
}
if (-not (Test-Path $Iscc)) {
  throw "Inno Setup compiler не найден: $Iscc"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$template = Get-Content (Join-Path $PSScriptRoot 'inno_setup.iss') -Raw
$template = [regex]::Replace(
  $template,
  '(?s)\[Languages\].*?\[Tasks\]',
  "[Languages]`r`nName: \"english\"; MessagesFile: \"compiler:Default.isl\"`r`nName: \"russian\"; MessagesFile: \"compiler:Languages\\Russian.isl\"`r`n`r`n[Tasks]"
)
$values = @{
  '{{APP_ID}}' = 'app.flclashm.client'
  '{{APP_VERSION}}' = $Version
  '{{DISPLAY_NAME}}' = 'FlClashM'
  '{{PUBLISHER_NAME}}' = 'makriq-org'
  '{{PUBLISHER_URL}}' = 'https://github.com/makriq-org/FlClashM'
  '{{INSTALL_DIR_NAME}}' = '{autopf}\FlClashM'
  '{{OUTPUT_BASE_FILENAME}}' = "FlClashM-windows-x64-$Version-setup"
  '{{SETUP_ICON_FILE}}' = (Resolve-Path (Join-Path $PSScriptRoot '..\..\runner\resources\app_icon.ico')).Path
  '{{PRIVILEGES_REQUIRED}}' = 'admin'
  '{{ARCH}}' = 'x64'
  '{{SOURCE_DIR}}' = $bundle
  '{{EXECUTABLE_NAME}}' = 'FlClashM.exe'
}
foreach ($entry in $values.GetEnumerator()) {
  $template = $template.Replace($entry.Key, $entry.Value)
}
$template = $template.Replace('{% if PRIVILEGES_REQUIRED == ''admin'' %}runascurrentuser{% endif %}', 'runascurrentuser')
$template = $template.Replace('{% if locale.lang == ''en'' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}', '')
$rendered = Join-Path $OutputDirectory 'FlClashM-windows-x64.iss'
Set-Content -Path $rendered -Value $template -NoNewline -Encoding utf8
& $Iscc "/O$OutputDirectory" $rendered
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup завершился с кодом $LASTEXITCODE"
}
