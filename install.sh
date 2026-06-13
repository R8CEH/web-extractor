#!/usr/bin/env bash
# ─── Web Extractor — Install / Update Script (Linux / macOS) ─────────────────
#
# Fresh install:
#   1. Detects the OS (Linux / macOS)
#   2. Checks for Python 3.10+
#   3. Checks for Hermes Agent
#   4. Downloads extractor.py and Readability.js from GitHub
#   5. Creates a virtual environment, installs dependencies, installs Chromium
#   6. Cleans up FIRECRAWL_API_* duplicates in .env and configures Hermes
#   7. Sets up auto-start: systemd (Linux) or launchd (macOS)
#   8. Starts the service and runs a health check
#
# Update (existing installation detected):
#   Downloads new files, updates Python dependencies, restarts the service.
#   Skips Chromium install and Hermes configuration.
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
#
# Re-run at any time to update to the latest version.
# ────────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────

DOWNLOAD_URL_EXTRACTOR="https://raw.githubusercontent.com/r8ceh/web-extractor/main/extractor.py"
DOWNLOAD_URL_READABILITY="https://raw.githubusercontent.com/r8ceh/web-extractor/main/Readability.js"

INSTALL_DIR="$HOME/.web-extractor"
VENV_DIR="$INSTALL_DIR/.venv"
EXTRACTOR_PATH="$INSTALL_DIR/extractor.py"
SERVICE_PORT="3002"
HERMES_HOME="$HOME/.hermes"
HERMES_ENV="$HERMES_HOME/.env"

# ─── Colors ─────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step()  { echo -e "\n${BOLD}${CYAN}─── $1${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
info()  { echo -e "    $1"; }

die() {
    echo -e "\n${RED}${BOLD}ERROR:${NC} $1"
    exit 1
}

# ─── Detect install vs update mode ──────────────────────────────────────────────

IS_UPDATE=false
CURRENT_VERSION="(not installed)"

if [ -f "$EXTRACTOR_PATH" ]; then
    IS_UPDATE=true
    CURRENT_VERSION=$(grep -o '__version__ = "[^"]*"' "$EXTRACTOR_PATH" \
        | cut -d'"' -f2 2>/dev/null || echo "unknown")
    echo -e "${BOLD}${CYAN}▶ Update mode — upgrading from v${CURRENT_VERSION}${NC}"
else
    echo -e "${BOLD}${CYAN}▶ Fresh install${NC}"
fi

# ─── Step 0: Detect OS ──────────────────────────────────────────────────────────

step "Step 0: Detecting operating system"

OS="$(uname -s)"
case "$OS" in
    Linux)  OS_TYPE="linux";   ok "Linux"    ;;
    Darwin) OS_TYPE="macos";   ok "macOS"    ;;
    *)      die "Unsupported OS: $OS. This script works on Linux and macOS only." ;;
esac

# ─── Step 1: Check Python ───────────────────────────────────────────────────────

step "Step 1: Checking Python 3.10+"

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || true)
        if [ -n "$ver" ]; then
            major=$(echo "$ver" | cut -d. -f1)
            minor=$(echo "$ver" | cut -d. -f2)
            if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
                PYTHON="$candidate"
                ok "Found $candidate $ver"
                break
            fi
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    warn "Python 3.10+ not found"
    echo ""
    if [ "$OS_TYPE" = "linux" ]; then
        info "Install Python 3.10+ using your package manager:"
        info "  Ubuntu/Debian:  sudo apt install python3 python3-pip python3-venv"
        info "  Fedora:         sudo dnf install python3 python3-pip"
        info "  Arch:           sudo pacman -S python python-pip"
    else
        info "Install Python 3.10+ via Homebrew:"
        info "  brew install python@3.13"
    fi
    die "Python 3.10+ is required to run Web Extractor"
fi

if ! "$PYTHON" -m venv --help &>/dev/null; then
    warn "The venv module is not installed"
    if [ "$OS_TYPE" = "linux" ]; then
        info "Install it: sudo apt install python3-venv  (Debian/Ubuntu)"
    fi
    die "The venv module is required to create a virtual environment"
fi

# ─── Step 2: Check Hermes Agent ─────────────────────────────────────────────────

step "Step 2: Checking Hermes Agent"

HERMES_CMD=false
HERMES_DIR=false

if command -v hermes &>/dev/null; then
    ok "hermes command found in PATH"
    HERMES_CMD=true
else
    warn "hermes command not found in PATH — checking installation..."
fi

if [ -d "$HERMES_HOME" ]; then
    ok "~/.hermes/ directory found"
    HERMES_DIR=true
else
    warn "~/.hermes/ directory not found"
fi

if [ "$HERMES_CMD" = false ] && [ "$HERMES_DIR" = false ]; then
    echo ""
    info "Hermes Agent not detected."
    info "Please install Hermes Agent before running this script:"
    info "  https://github.com/nousresearch/hermes-agent"
    echo ""
    warn "Continuing without Hermes — you can run this script again later"
    warn "to configure Hermes after installing it."
    SKIP_HERMES=true
elif [ "$HERMES_CMD" = false ]; then
    warn "Hermes found at $HERMES_HOME but hermes command is not in PATH"
    warn "Skipping Hermes configuration — add hermes to PATH and re-run this script"
    SKIP_HERMES=true
else
    SKIP_HERMES=false
fi

# ─── Step 3: Download files from GitHub ─────────────────────────────────────────

step "Step 3: Downloading files"

mkdir -p "$INSTALL_DIR"

download_file() {
    local url="$1"
    local dest="$2"
    local name="$3"

    info "Downloading $name..."
    curl -sSL --connect-timeout 10 --max-time 30 -o "$dest" "$url" \
        || { rm -f "$dest"; die "Failed to download $name from $url"; }
    ok "$name downloaded ($(wc -c < "$dest") bytes)"
}

download_file "$DOWNLOAD_URL_EXTRACTOR"   "$EXTRACTOR_PATH"             "extractor.py"
download_file "$DOWNLOAD_URL_READABILITY" "$INSTALL_DIR/Readability.js" "Readability.js"

# ─── Step 4: Virtual environment and dependencies ───────────────────────────────

step "Step 4: Setting up Python virtual environment"

VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

if [ ! -d "$VENV_DIR" ]; then
    info "Creating venv at $VENV_DIR..."
    "$PYTHON" -m venv "$VENV_DIR"
    ok "Virtual environment created"
else
    ok "Virtual environment already exists"
fi

info "Upgrading pip..."
"$VENV_PIP" install --upgrade pip -q

info "Installing Python dependencies..."
"$VENV_PIP" install fastapi uvicorn markdownify playwright cachetools -q

if [ "$IS_UPDATE" = false ]; then
    info "Installing Playwright Chromium..."
    if ! "$VENV_DIR/bin/playwright" install chromium 2>&1 | tail -1; then
        warn "Failed to install Chromium — trying to install system dependencies..."
        if [ "$OS_TYPE" = "linux" ]; then
            "$VENV_DIR/bin/playwright" install-deps chromium 2>&1 || true
            "$VENV_DIR/bin/playwright" install chromium 2>&1 || \
                die "Failed to install Playwright Chromium"
        else
            die "Failed to install Playwright Chromium"
        fi
    fi
    ok "Playwright Chromium installed"

    info "Installing Firecrawl SDK (for Hermes Agent)..."
    "$VENV_PIP" install firecrawl -q || warn "Firecrawl SDK not installed (Hermes may use its own)"
else
    ok "Skipping Chromium install (update mode)"
fi

ok "All dependencies installed"

# ─── Step 5: Clean up duplicates in Hermes .env ─────────────────────────────────

if [ "$IS_UPDATE" = false ] && [ "$SKIP_HERMES" = false ]; then
    step "Step 5: Checking Hermes configuration"

    for KEY in FIRECRAWL_API_URL FIRECRAWL_API_KEY; do
        if [ -f "$HERMES_ENV" ]; then
            count=$(grep -c "^${KEY}=" "$HERMES_ENV" 2>/dev/null || true)
            if [ "$count" -gt 1 ]; then
                warn "Found $count duplicates of $KEY in ~/.hermes/.env — removing all, keeping the last one"
                last_value=$(grep "^${KEY}=" "$HERMES_ENV" | tail -1 | cut -d= -f2-)
                if [ "$OS_TYPE" = "macos" ]; then
                    sed -i '' "/^${KEY}=/d" "$HERMES_ENV"
                else
                    sed -i "/^${KEY}=/d" "$HERMES_ENV"
                fi
                echo "${KEY}=${last_value}" >> "$HERMES_ENV"
                ok "Duplicates of $KEY fixed"
            elif [ "$count" -eq 1 ]; then
                ok "$KEY already set (1 occurrence)"
            else
                info "$KEY not yet set in .env"
            fi
        fi
    done
elif [ "$IS_UPDATE" = true ]; then
    step "Step 5: Checking Hermes configuration — skipped (update mode)"
else
    step "Step 5: Checking Hermes configuration — skipped (Hermes not found)"
fi

# ─── Step 6: Configure Hermes ───────────────────────────────────────────────────

if [ "$IS_UPDATE" = false ] && [ "$SKIP_HERMES" = false ]; then
    step "Step 6: Configuring Hermes Agent"

    info "web.extract_backend → firecrawl"
    hermes config set web.extract_backend firecrawl
    ok "web.extract_backend = firecrawl"

    info "FIRECRAWL_API_URL → http://127.0.0.1:$SERVICE_PORT"
    hermes config set FIRECRAWL_API_URL "http://127.0.0.1:$SERVICE_PORT"
    ok "FIRECRAWL_API_URL = http://127.0.0.1:$SERVICE_PORT"

    info "FIRECRAWL_API_KEY → local"
    hermes config set FIRECRAWL_API_KEY local
    ok "FIRECRAWL_API_KEY = local"
elif [ "$IS_UPDATE" = true ]; then
    step "Step 6: Configuring Hermes Agent — skipped (update mode)"
else
    step "Step 6: Configuring Hermes Agent — skipped (Hermes not found)"
    info "Once Hermes is installed, run:"
    info "  hermes config set web.extract_backend firecrawl"
    info "  hermes config set FIRECRAWL_API_URL http://127.0.0.1:$SERVICE_PORT"
    info "  hermes config set FIRECRAWL_API_KEY local"
fi

# ─── Step 7: Auto-start ─────────────────────────────────────────────────────────

step "Step 7: Setting up auto-start"

CURRENT_USER="$(whoami)"

if [ "$OS_TYPE" = "linux" ]; then
    # ── systemd ─────────────────────────────────────────────────────────────
    SERVICE_NAME="web-extractor"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ "$IS_UPDATE" = true ]; then
        info "Restarting service..."
        if sudo systemctl restart "$SERVICE_NAME" 2>&1; then
            ok "Service restarted"
        else
            warn "Failed to restart service — check logs: sudo journalctl -u $SERVICE_NAME -n 20"
        fi
    else
        SERVICE_CONTENT="[Unit]
Description=Web Extractor — self-hosted Firecrawl-compatible web extractor
After=network.target

[Service]
Type=simple
User=${CURRENT_USER}
ExecStart=${VENV_PYTHON} ${EXTRACTOR_PATH}
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target"

        if [ -f "$SERVICE_FILE" ]; then
            warn "systemd unit already exists: $SERVICE_FILE"
            info "Stopping and recreating..."
            sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        fi

        echo "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
        ok "Unit created: $SERVICE_FILE"

        sudo systemctl daemon-reload
        sudo systemctl enable "$SERVICE_NAME"
        ok "Auto-start enabled (systemctl enable)"

        if sudo systemctl start "$SERVICE_NAME" 2>&1; then
            ok "Service started"
        else
            warn "Failed to start service — check logs: sudo journalctl -u $SERVICE_NAME -n 20"
        fi
    fi

elif [ "$OS_TYPE" = "macos" ]; then
    # ── launchd ─────────────────────────────────────────────────────────────
    PLIST_LABEL="com.web-extractor"
    PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
    STDOUT_LOG="/tmp/web-extractor.stdout"
    STDERR_LOG="/tmp/web-extractor.stderr"

    if [ "$IS_UPDATE" = true ]; then
        info "Restarting service..."
        if launchctl kickstart -k "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null; then
            ok "Service restarted"
        else
            warn "Failed to restart service"
            info "Logs: $STDERR_LOG"
        fi
    else
        mkdir -p "$HOME/Library/LaunchAgents"

        PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\"
  \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${VENV_PYTHON}</string>
        <string>${EXTRACTOR_PATH}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${STDOUT_LOG}</string>

    <key>StandardErrorPath</key>
    <string>${STDERR_LOG}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
</dict>
</plist>"

        if [ -f "$PLIST_FILE" ]; then
            warn "launchd agent already exists — unloading old one..."
            if launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null; then
                ok "Old agent unloaded"
            else
                warn "Failed to unload old agent (may not be running)"
            fi
        fi

        echo "$PLIST_CONTENT" > "$PLIST_FILE"
        ok "plist created: $PLIST_FILE"

        if launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE" 2>&1; then
            ok "Agent loaded into launchd"
        else
            warn "Failed to load agent into launchd"
            info "Check the plist manually: $PLIST_FILE"
            info "Logs: $STDERR_LOG"
        fi
    fi
fi

# ─── Step 8: Health check ──────────────────────────────────────────────────────

step "Step 8: Verifying service health"

sleep 2

HEALTH_URL="http://127.0.0.1:${SERVICE_PORT}/health"
HEALTH_RESPONSE=$(curl -s --connect-timeout 2 --max-time 5 "$HEALTH_URL" || true)

if echo "$HEALTH_RESPONSE" | grep -q '"status":"ok"'; then
    ok "Health check passed: $HEALTH_RESPONSE"
else
    warn "Health check failed — the service may still be starting up"
    warn "Check manually: curl $HEALTH_URL"
    if [ "$OS_TYPE" = "linux" ]; then
        info "Logs: sudo journalctl -u web-extractor -n 20"
    else
        info "Logs: cat $STDERR_LOG"
    fi
fi

# ─── Summary ────────────────────────────────────────────────────────────────────

NEW_VERSION=$(grep -o '__version__ = "[^"]*"' "$EXTRACTOR_PATH" \
    | cut -d'"' -f2 2>/dev/null || echo "unknown")

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
if [ "$IS_UPDATE" = true ]; then
    echo -e "${BOLD}${GREEN}  Web Extractor updated!${NC}"
else
    echo -e "${BOLD}${GREEN}  Web Extractor installed!${NC}"
fi
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
if [ "$IS_UPDATE" = true ]; then
    echo -e "  Updated:       ${BOLD}v${CURRENT_VERSION} → v${NEW_VERSION}${NC}"
else
    echo -e "  Version:       ${BOLD}v${NEW_VERSION}${NC}"
fi
echo -e "  Service:       ${BOLD}http://127.0.0.1:${SERVICE_PORT}${NC}"
echo -e "  Health:        ${BOLD}curl http://127.0.0.1:${SERVICE_PORT}/health${NC}"
echo -e "  Directory:     ${BOLD}${INSTALL_DIR}${NC}"
echo -e "  Venv Python:   ${BOLD}${VENV_PYTHON}${NC}"
echo ""
echo -e "  Useful commands:"
if [ "$OS_TYPE" = "linux" ]; then
    echo -e "    sudo systemctl status web-extractor"
    echo -e "    sudo systemctl restart web-extractor"
    echo -e "    sudo journalctl -u web-extractor -f"
else
    echo -e "    launchctl list | grep web-extractor"
    echo -e "    tail -f ${STDERR_LOG}"
fi
echo ""
