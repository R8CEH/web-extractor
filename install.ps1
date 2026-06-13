# ─── Web Extractor — Install / Update Script (Windows) ───────────────────────
#
# Fresh install:
#   1. Checks for Python 3.10+
#   2. Checks for Hermes Agent
#   3. Downloads extractor.py and Readability.js from GitHub
#   4. Creates a virtual environment, installs dependencies, installs Chromium
#   5. Cleans up FIRECRAWL_API_* duplicates in .env and configures Hermes
#   6. Sets up auto-start via Task Scheduler
#   7. Starts the service and runs a health check
#
# Update (existing installation detected):
#   Downloads new files, updates Python dependencies, restarts the service.
#   Skips Chromium install and Hermes configuration.
#
# Usage:
#   Run PowerShell as Administrator (required for Task Scheduler):
#     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#     .\install.ps1
#
#   Or one-line:
#     powershell -ExecutionPolicy Bypass -File install.ps1
#
# Re-run at any time to update to the latest version.
# ────────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

# ─── Configuration ──────────────────────────────────────────────────────────────

$DownloadUrlExtractor   = "https://raw.githubusercontent.com/r8ceh/web-extractor/main/extractor.py"
$DownloadUrlReadability = "https://raw.githubusercontent.com/r8ceh/web-extractor/main/Readability.js"

$InstallDir    = "$env:USERPROFILE\web-extractor"
$VenvDir       = "$InstallDir\.venv"
$ExtractorPath = "$InstallDir\extractor.py"
$ServicePort   = 3002
$HermesHome    = "$env:LOCALAPPDATA\hermes"
$HermesEnv     = "$HermesHome\.env"

if (-not (Test-Path "$env:LOCALAPPDATA")) {
    $HermesHome = "$env:USERPROFILE\.hermes"
    $HermesEnv  = "$HermesHome\.env"
}

# ─── Output helpers ─────────────────────────────────────────────────────────────

function Write-Step($msg) { Write-Host "`n─── $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  v $msg"  -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ! $msg"  -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  x $msg"  -ForegroundColor Red }
function Write-Info($msg) { Write-Host "    $msg" }

function Die($msg) {
    Write-Host "`nERROR: $msg" -ForegroundColor Red
    exit 1
}

# ─── Detect install vs update mode ──────────────────────────────────────────────

$IsUpdate       = $false
$CurrentVersion = "(not installed)"

if (Test-Path $ExtractorPath) {
    $IsUpdate = $true
    $m = Select-String -Path $ExtractorPath -Pattern '__version__ = "([^"]+)"' -ErrorAction SilentlyContinue
    $CurrentVersion = if ($m) { $m.Matches[0].Groups[1].Value } else { "unknown" }
    Write-Host "`n> Update mode - upgrading from v$CurrentVersion" -ForegroundColor Cyan
} else {
    Write-Host "`n> Fresh install" -ForegroundColor Cyan
}

# ─── Step 0: Check privileges ──────────────────────────────────────────────────

Write-Step "Step 0: Checking privileges"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-OK "Running as Administrator"
} else {
    Write-Warn "Not running as Administrator"
    Write-Info "Task Scheduler setup requires Administrator privileges."
    Write-Info "If it fails, re-run this script as Administrator."
    Write-Info "All other steps work without elevated privileges."
}

# ─── Step 1: Check Python ───────────────────────────────────────────────────────

Write-Step "Step 1: Checking Python 3.10+"

$PythonExe = $null
foreach ($candidate in @("python3", "python", "py")) {
    $found = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($found) {
        try {
            $verOutput = & $candidate -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            if ($verOutput -match '^(\d+)\.(\d+)$') {
                $major = [int]$Matches[1]
                $minor = [int]$Matches[2]
                if ($major -ge 3 -and $minor -ge 10) {
                    $PythonExe = $candidate
                    Write-OK "Found $candidate $verOutput"
                    break
                }
            }
        } catch { }
    }
}

if (-not $PythonExe) {
    Write-Warn "Python 3.10+ not found"
    Write-Info ""
    Write-Info "Install Python 3.10+ from https://www.python.org/downloads/"
    Write-Info "Make sure to check 'Add Python to PATH' during installation."
    Die "Python 3.10+ is required to run Web Extractor"
}

# ─── Step 2: Check Hermes Agent ─────────────────────────────────────────────────

Write-Step "Step 2: Checking Hermes Agent"

$HermesCmd = $false
$HermesDir = $false

if (Get-Command hermes -ErrorAction SilentlyContinue) {
    Write-OK "hermes command found in PATH"
    $HermesCmd = $true
} else {
    Write-Warn "hermes command not found in PATH — checking installation..."
}

if (Test-Path $HermesHome) {
    Write-OK "Hermes directory found: $HermesHome"
    $HermesDir = $true
} else {
    Write-Warn "Hermes directory not found: $HermesHome"
}

if (-not $HermesCmd -and -not $HermesDir) {
    Write-Info ""
    Write-Info "Hermes Agent not detected."
    Write-Info "Please install Hermes Agent before running this script:"
    Write-Info "  https://github.com/nousresearch/hermes-agent"
    Write-Info ""
    Write-Warn "Continuing without Hermes — you can run this script again later"
    Write-Warn "to configure Hermes after installing it."
    $Script:SkipHermes = $true
} elseif (-not $HermesCmd) {
    Write-Warn "Hermes found at $HermesHome but hermes command is not in PATH"
    Write-Warn "Skipping Hermes configuration — add hermes to PATH and re-run this script"
    $Script:SkipHermes = $true
} else {
    $Script:SkipHermes = $false
}

# ─── Step 3: Download files from GitHub ─────────────────────────────────────────

Write-Step "Step 3: Downloading files"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

function Download-File($url, $dest, $name) {
    Write-Info "Downloading $name..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 30
        $size = (Get-Item $dest).Length
        Write-OK "$name downloaded ($size bytes)"
    } catch {
        if (Test-Path $dest) { Remove-Item $dest -Force }
        Die "Failed to download $name from ${url}: $_"
    }
}

Download-File $DownloadUrlExtractor   $ExtractorPath              "extractor.py"
Download-File $DownloadUrlReadability "$InstallDir\Readability.js" "Readability.js"

# ─── Step 4: Virtual environment and dependencies ───────────────────────────────

Write-Step "Step 4: Setting up Python virtual environment"

$VenvPython = "$VenvDir\Scripts\python.exe"
$VenvPip    = "$VenvDir\Scripts\pip.exe"

if (-not (Test-Path $VenvDir)) {
    Write-Info "Creating venv at $VenvDir..."
    & $PythonExe -m venv $VenvDir
    Write-OK "Virtual environment created"
} else {
    Write-OK "Virtual environment already exists"
}

Write-Info "Upgrading pip..."
& $VenvPython -m pip install --upgrade pip -q

Write-Info "Installing Python dependencies..."
& $VenvPip install fastapi uvicorn markdownify playwright cachetools -q

if (-not $IsUpdate) {
    Write-Info "Installing Playwright Chromium..."
    try {
        & "$VenvDir\Scripts\playwright.exe" install chromium 2>&1 | Select-Object -Last 1
        Write-OK "Playwright Chromium installed"
    } catch {
        Write-Warn "Failed to install Chromium — trying system dependencies..."
        try {
            & "$VenvDir\Scripts\playwright.exe" install-deps chromium 2>&1
            & "$VenvDir\Scripts\playwright.exe" install chromium 2>&1
            Write-OK "Playwright Chromium installed"
        } catch {
            Die "Failed to install Playwright Chromium"
        }
    }

    Write-Info "Installing Firecrawl SDK (for Hermes Agent)..."
    try {
        & $VenvPip install firecrawl -q
    } catch {
        Write-Warn "Firecrawl SDK not installed (Hermes may use its own)"
    }
} else {
    Write-OK "Skipping Chromium install (update mode)"
}

Write-OK "All dependencies installed"

# ─── Step 5: Clean up duplicates in Hermes .env ─────────────────────────────────

if (-not $IsUpdate -and -not $Script:SkipHermes) {
    Write-Step "Step 5: Checking Hermes configuration"

    foreach ($Key in @("FIRECRAWL_API_URL", "FIRECRAWL_API_KEY")) {
        if (Test-Path $HermesEnv) {
            $lines    = Get-Content $HermesEnv -ErrorAction SilentlyContinue
            $matching = @($lines | Where-Object { $_ -match "^${Key}=" })
            $count    = $matching.Count

            if ($count -gt 1) {
                Write-Warn "Found $count duplicates of $Key in .env — removing all, keeping the last one"
                $lastValue = ($matching | Select-Object -Last 1) -replace "^${Key}=", ""
                $filtered  = @($lines | Where-Object { $_ -notmatch "^${Key}=" })
                $filtered += "${Key}=${lastValue}"
                [System.IO.File]::WriteAllLines($HermesEnv, $filtered, [System.Text.UTF8Encoding]::new($false))
                Write-OK "Duplicates of $Key fixed"
            } elseif ($count -eq 1) {
                Write-OK "$Key already set (1 occurrence)"
            } else {
                Write-Info "$Key not yet set in .env"
            }
        }
    }
} elseif ($IsUpdate) {
    Write-Step "Step 5: Checking Hermes configuration — skipped (update mode)"
} else {
    Write-Step "Step 5: Checking Hermes configuration — skipped (Hermes not found)"
}

# ─── Step 6: Configure Hermes ───────────────────────────────────────────────────

if (-not $IsUpdate -and -not $Script:SkipHermes) {
    Write-Step "Step 6: Configuring Hermes Agent"

    Write-Info "web.extract_backend -> firecrawl"
    hermes config set web.extract_backend firecrawl
    Write-OK "web.extract_backend = firecrawl"

    Write-Info "FIRECRAWL_API_URL -> http://127.0.0.1:$ServicePort"
    hermes config set FIRECRAWL_API_URL "http://127.0.0.1:$ServicePort"
    Write-OK "FIRECRAWL_API_URL = http://127.0.0.1:$ServicePort"

    Write-Info "FIRECRAWL_API_KEY -> local"
    hermes config set FIRECRAWL_API_KEY local
    Write-OK "FIRECRAWL_API_KEY = local"
} elseif ($IsUpdate) {
    Write-Step "Step 6: Configuring Hermes Agent — skipped (update mode)"
} else {
    Write-Step "Step 6: Configuring Hermes Agent — skipped (Hermes not found)"
    Write-Info "Once Hermes is installed, run:"
    Write-Info "  hermes config set web.extract_backend firecrawl"
    Write-Info "  hermes config set FIRECRAWL_API_URL http://127.0.0.1:$ServicePort"
    Write-Info "  hermes config set FIRECRAWL_API_KEY local"
}

# ─── Step 7: Auto-start (Task Scheduler) ────────────────────────────────────────

Write-Step "Step 7: Setting up auto-start (Task Scheduler)"

$TaskName = "WebExtractor"

if ($IsUpdate) {
    Write-Info "Restarting service..."
    try {
        Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
        Write-OK "Service restarted"
    } catch {
        Write-Warn "Failed to restart service: $_"
        Write-Info "Start manually: Start-ScheduledTask -TaskName $TaskName"
    }
} else {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warn "Task '$TaskName' already exists — removing old one..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    try {
        $Action = New-ScheduledTaskAction `
            -Execute "$VenvPython" `
            -Argument "`"$ExtractorPath`"" `
            -WorkingDirectory "$InstallDir"

        $Trigger = New-ScheduledTaskTrigger -AtStartup

        $Principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType S4U `
            -RunLevel Highest

        $Settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit (New-TimeSpan -Days 0)

        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $Action `
            -Trigger $Trigger `
            -Principal $Principal `
            -Settings $Settings `
            -Description "Web Extractor — self-hosted Firecrawl-compatible web extractor" `
            -Force | Out-Null

        Write-OK "Task '$TaskName' created in Task Scheduler"

        Start-ScheduledTask -TaskName $TaskName
        Write-OK "Task '$TaskName' started"

    } catch {
        if ($isAdmin) {
            Write-Fail "Failed to create scheduled task: $_"
            Write-Info "Try creating the task manually via Task Scheduler GUI."
        } else {
            Write-Warn "Failed to create task (likely missing Administrator privileges)"
            Write-Info "Re-run this script as Administrator to enable auto-start,"
            Write-Info "or create the task manually:"
            Write-Info "  1. Open Task Scheduler"
            Write-Info "  2. Create Basic Task -> name: WebExtractor"
            Write-Info "  3. Trigger: When the computer starts"
            Write-Info "  4. Action: Start a program"
            Write-Info "     Program:   $VenvPython"
            Write-Info "     Arguments: $ExtractorPath"
            Write-Info "     Start in:  $InstallDir"
        }
        Write-Info ""
        Write-Warn "Service NOT started automatically. Start manually:"
        Write-Info "  & $VenvPython $ExtractorPath"
    }
}

# ─── Step 8: Health check ──────────────────────────────────────────────────────

Write-Step "Step 8: Verifying service health"

Start-Sleep -Seconds 3

$HealthUrl = "http://127.0.0.1:${ServicePort}/health"

try {
    $response = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 5 -UseBasicParsing
    if ($response.Content -match '"status":"ok"') {
        Write-OK "Health check passed: $($response.Content)"
    } else {
        Write-Warn "Health check: unexpected response: $($response.Content)"
    }
} catch {
    Write-Warn "Health check failed — the service may still be starting up"
    Write-Warn "Check manually: Invoke-WebRequest $HealthUrl"
    Write-Info "Task info: Get-ScheduledTaskInfo -TaskName $TaskName"
}

# ─── Summary ────────────────────────────────────────────────────────────────────

$mNew       = Select-String -Path $ExtractorPath -Pattern '__version__ = "([^"]+)"' -ErrorAction SilentlyContinue
$NewVersion = if ($mNew) { $mNew.Matches[0].Groups[1].Value } else { "unknown" }

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Green
if ($IsUpdate) {
    Write-Host "  Web Extractor updated!" -ForegroundColor Green
} else {
    Write-Host "  Web Extractor installed!" -ForegroundColor Green
}
Write-Host "=======================================================" -ForegroundColor Green
Write-Host ""
if ($IsUpdate) {
    Write-Host "  Updated:       v$CurrentVersion -> v$NewVersion"
} else {
    Write-Host "  Version:       v$NewVersion"
}
Write-Host "  Service:       http://127.0.0.1:${ServicePort}"
Write-Host "  Health:        curl http://127.0.0.1:${ServicePort}/health"
Write-Host "  Directory:     $InstallDir"
Write-Host "  Venv Python:   $VenvPython"
Write-Host ""
Write-Host "  Useful commands:"
Write-Host "    Get-ScheduledTask     -TaskName $TaskName"
Write-Host "    Start-ScheduledTask   -TaskName $TaskName"
Write-Host "    Stop-ScheduledTask    -TaskName $TaskName"
Write-Host "    & $VenvPython $ExtractorPath    (manual start)"
Write-Host ""
