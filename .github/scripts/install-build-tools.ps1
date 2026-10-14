# Installs the build tools on a GitHub Actions Windows runner and exports their paths
# (AHK, AHK2EXE, ISCC) for later steps. Versions are pinned so builds are reproducible.
param(
    [string]$AhkVersion = "2.0.30",
    [string]$Ahk2ExeTag = "Ahk2Exe1.1.37.02a2"
)
$ErrorActionPreference = "Stop"
$tools = Join-Path $env:RUNNER_TEMP "build-tools"
New-Item -ItemType Directory -Force $tools | Out-Null

function Get-Zip([string]$url, [string]$name) {
    $zip = Join-Path $tools "$name.zip"
    Invoke-WebRequest $url -OutFile $zip
    Expand-Archive $zip (Join-Path $tools $name) -Force
    return Join-Path $tools $name
}

$ahkDir = Get-Zip "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$AhkVersion/AutoHotkey_$AhkVersion.zip" "autohotkey"
$ahk2exeDir = Get-Zip "https://github.com/AutoHotkey/Ahk2Exe/releases/download/$Ahk2ExeTag/$Ahk2ExeTag.zip" "ahk2exe"
choco install innosetup -y --no-progress | Out-Host

# Zip layouts can change between versions, so look the executables up instead of assuming paths.
$ahk = Get-ChildItem $ahkDir -Recurse -Filter AutoHotkey64.exe | Select-Object -First 1
$ahk2exe = Get-ChildItem $ahk2exeDir -Recurse -Filter Ahk2Exe.exe | Select-Object -First 1
$iscc = Get-ChildItem "C:\Program Files*\Inno Setup*\ISCC.exe" | Select-Object -First 1
foreach ($tool in @{AutoHotkey64 = $ahk; Ahk2Exe = $ahk2exe; ISCC = $iscc}.GetEnumerator()) {
    if (-not $tool.Value) { throw "$($tool.Key).exe not found after install" }
}

"AHK=$($ahk.FullName)" >> $env:GITHUB_ENV
"AHK2EXE=$($ahk2exe.FullName)" >> $env:GITHUB_ENV
"ISCC=$($iscc.FullName)" >> $env:GITHUB_ENV
"AutoHotkey $AhkVersion, $Ahk2ExeTag, $((Get-Item $iscc.FullName).VersionInfo.ProductName) $((Get-Item $iscc.FullName).VersionInfo.ProductVersion)"
