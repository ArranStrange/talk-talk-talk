# Build the Windows installer: the tray app (self-contained, no .NET install
# needed), the speech engine with its own Python and the voice models, all
# in one per-user setup.exe.
#
#   powershell -ExecutionPolicy Bypass -File windows\package.ps1 [-Version 1.2.3]
#
# Needs: .NET 10 SDK, Python 3.10+ (only to run the build script), Visual
# Studio Build Tools (llama-cpp-python compiles), Inno Setup 6.
#
# Signing: set BELLOWFLO_SIGN_PFX (path) and BELLOWFLO_SIGN_PASSWORD to sign
# the app and the installer with signtool. Unsigned, Windows SmartScreen
# shows "Windows protected your PC" until More info → Run anyway.
param([string]$Version = "0.0.0-dev")

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Dist = Join-Path $Repo "dist"
$Out = Join-Path $Dist "windows\app"
function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null

Say "Publishing the tray app"
$ver = $Version.TrimStart("v") -replace '[^0-9.].*$', ''
if (-not $ver) { $ver = "0.0.0" }
dotnet publish (Join-Path $PSScriptRoot "BellowFlo\BellowFlo.csproj") -c Release -r win-x64 `
    --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:Version=$ver -o $Out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Get-ChildItem $Out -Filter *.pdb | Remove-Item

Say "Bundling the engine"
python (Join-Path $Repo "packaging\build_engine.py") --platform windows --out (Join-Path $Out "engine")
if ($LASTEXITCODE -ne 0) { throw "engine build failed" }

function Sign($file) {
    if (-not $env:BELLOWFLO_SIGN_PFX) { return }
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
        Sort-Object FullName -Descending | Select-Object -First 1
    & $signtool.FullName sign /f $env:BELLOWFLO_SIGN_PFX /p $env:BELLOWFLO_SIGN_PASSWORD `
        /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $file
    if ($LASTEXITCODE -ne 0) { throw "signing $file failed" }
}
Sign (Join-Path $Out "BellowFlo.exe")

Say "Building the installer"
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found (winget install JRSoftware.InnoSetup)" }
& $iscc "/DAppVersion=$($Version.TrimStart('v'))" "/DSourceDir=$Out" (Join-Path $PSScriptRoot "installer\BellowFlo.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
$setup = Get-ChildItem $Dist -Filter "BellowFlo-*-windows-x64-setup.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Sign $setup.FullName
Say ("Built: {0} ({1:N0} MB)" -f $setup.FullName, ($setup.Length / 1MB))
