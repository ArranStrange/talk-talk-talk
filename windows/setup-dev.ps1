# Set up Bellow Flo on Windows from a source checkout, for development and
# testing. Not the end-user installer (that is stage 3): this expects Python
# 3.11-3.13 and the .NET 10 SDK to be installed already.
#
#   powershell -ExecutionPolicy Bypass -File windows\setup-dev.ps1
#
# Safe to run again: each step skips what is already done.

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Kokoro = Join-Path $Repo "kokoro"
$Venv = Join-Path $Kokoro "venv"
$Py = Join-Path $Venv "Scripts\python.exe"

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# --- 1. Python ------------------------------------------------------------------
if (-not (Test-Path $Py)) {
    $base = $null
    foreach ($v in "3.13", "3.12", "3.11") {
        try { & py "-$v" -c "import sys" 2>$null; if ($LASTEXITCODE -eq 0) { $base = @("py", "-$v"); break } } catch {}
    }
    if (-not $base) { throw "Python 3.11-3.13 not found. Install it from python.org (tick 'py launcher')." }
    Say "Creating the venv with $($base -join ' ')"
    & $base[0] $base[1] -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed" }
}

# --- 2. Packages ------------------------------------------------------------------
# kokoro-onnx brings onnxruntime and espeakng-loader (a bundled espeak-ng, so
# no separate install). llama-cpp-python comes from its prebuilt CPU wheels:
# from PyPI it compiles from source, which needs Visual Studio.
Say "Installing the speech and dictation packages"
& $Py -m pip install --quiet --upgrade pip
& $Py -m pip install --quiet kokoro-onnx soundfile sounddevice onnx-asr huggingface_hub
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
& $Py -m pip install --quiet --prefer-binary llama-cpp-python `
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu
if ($LASTEXITCODE -ne 0) { throw "llama-cpp-python install failed" }

# --- 3. Data folder and voice models -----------------------------------------------
$Data = (& $Py (Join-Path $Kokoro "bf_paths.py")).Trim()
Say "Data folder: $Data"
Say "Downloading voice models (about 340 MB, first run only)"
& $Py (Join-Path $Kokoro "bf_paths.py") models
if ($LASTEXITCODE -ne 0) { throw "model download failed" }

# --- 4. Smoke test: speak through the engine ----------------------------------------
Say "Testing speech"
& $Py -X utf8 (Join-Path $Kokoro "ktts") say "Bellow Flo is set up on Windows."
if ($LASTEXITCODE -ne 0) { Write-Warning "The speech test failed; see $Data\daemon.log" }

# --- 5. Build the tray app ------------------------------------------------------------
Say "Building the tray app"
$Proj = Join-Path $PSScriptRoot "BellowFlo\BellowFlo.csproj"
dotnet build $Proj -c Release
if ($LASTEXITCODE -ne 0) { throw "build failed" }
$Exe = Join-Path $PSScriptRoot "BellowFlo\bin\Release\net10.0-windows\BellowFlo.exe"
Say "Done. Start it with:`n    $Exe"
