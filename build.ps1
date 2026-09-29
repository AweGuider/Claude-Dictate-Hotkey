<#
Builds dist\ with: ClaudeDictateHotkey.exe, a portable zip, the installer, and SHA256SUMS.txt.
Version comes from the ;@Ahk2Exe-SetVersion line in ClaudeDictateHotkey.ahk.

  .\build.ps1                                  # uses default tool locations
  .\build.ps1 -Ahk2Exe D:\Tools\Ahk2Exe.exe    # or set $env:AHK2EXE
  .\build.ps1 -SkipInstaller
#>
param(
    [string]$Ahk2Exe,
    [string]$AhkBase = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
    [string]$Iscc,
    [switch]$SkipInstaller
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dist = Join-Path $root "dist"
$script = Join-Path $root "ClaudeDictateHotkey.ahk"

function Resolve-Tool([string]$explicit, [string[]]$candidates, [string]$name) {
    foreach ($path in @($explicit) + $candidates) {
        if ($path -and (Test-Path $path)) { return (Resolve-Path $path).Path }
    }
    throw "$name not found. Pass its path as a parameter (see the top of build.ps1)."
}

$Ahk2Exe = Resolve-Tool $Ahk2Exe @($env:AHK2EXE, "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe") "Ahk2Exe"
if (-not (Test-Path $AhkBase)) { throw "AutoHotkey v2 base not found: $AhkBase" }

$version = (Select-String -Path $script -Pattern '^;@Ahk2Exe-SetVersion\s+(\S+)').Matches[0].Groups[1].Value
if (-not $version) { throw "No ;@Ahk2Exe-SetVersion line in $script" }
Write-Host "Building Claude Dictate Hotkey $version"

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory $dist | Out-Null
$exe = Join-Path $dist "ClaudeDictateHotkey.exe"

# /compress 0: packed executables trigger more antivirus false positives.
$proc = Start-Process $Ahk2Exe -Wait -PassThru -NoNewWindow -ArgumentList @(
    "/in", "`"$script`"", "/out", "`"$exe`"", "/base", "`"$AhkBase`"", "/compress", "0", "/silent", "verbose")
if ($proc.ExitCode -ne 0 -or -not (Test-Path $exe)) { throw "Ahk2Exe failed (exit $($proc.ExitCode))" }

$staging = Join-Path $dist "portable"
New-Item -ItemType Directory $staging | Out-Null
Copy-Item $exe, (Join-Path $root "Settings.bat"), (Join-Path $root "README.md"), (Join-Path $root "LICENSE") $staging
$zip = Join-Path $dist "ClaudeDictateHotkey-$version-portable.zip"
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip
Remove-Item $staging -Recurse -Force

if (-not $SkipInstaller) {
    $Iscc = Resolve-Tool $Iscc @("C:\Program Files\Inno Setup 7\ISCC.exe", "C:\Program Files (x86)\Inno Setup 6\ISCC.exe") "Inno Setup (ISCC.exe)"
    & $Iscc /Qp "/DAppVersion=$version" (Join-Path $root "installer\ClaudeDictateHotkey.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed (exit $LASTEXITCODE)" }
}

$sums = Get-ChildItem $dist -File -Include *.exe, *.zip -Recurse | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
}
$sums | Set-Content (Join-Path $dist "SHA256SUMS.txt") -Encoding ascii
$sums | Write-Host
