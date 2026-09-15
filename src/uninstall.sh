#!/bin/bash

set -u

# --------------------------------------------------
# Safe Execution Trap: Prevent deleting running script
# --------------------------------------------------
if [[ "$0" == "/opt/proton-launcher/"* ]]; then
    echo "Relocating uninstaller to /tmp to safely remove /opt/proton-launcher..."
    cp "$0" /tmp/proton-uninstall.sh
    chmod +x /tmp/proton-uninstall.sh
    exec /tmp/proton-uninstall.sh "$@"
fi

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run uninstall.sh as root/sudo."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

INSTALL_DIR="/opt/proton-launcher"
BIN_LINK="/usr/local/bin/proton-launcher"
DESKTOP_DIR="$USER_HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/proton-launcher.desktop"
CE_DESKTOP_FILE="$DESKTOP_DIR/cheat-engine.desktop"
GAME_LAUNCHER_DIR="$USER_HOME/.local/share/game-launcher"

echo "=========================================="
echo "        Proton Launcher Uninstall"
echo "=========================================="
echo

confirm() {
    local prompt="$1"
    local reply
    read -r -p "$prompt [y/N] " reply
    case "$reply" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Remove system links and target /opt folder safely
echo "Removing system installation..."

if [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ]; then
    rm -f "$BIN_LINK"
    echo "[OK] Removed $BIN_LINK"
fi

if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "[OK] Removed $INSTALL_DIR"
fi

if [ -f "$DESKTOP_FILE" ]; then
    rm -f "$DESKTOP_FILE"
    echo "[OK] Removed $DESKTOP_FILE"
fi

if [ -f "$CE_DESKTOP_FILE" ]; then
    rm -f "$CE_DESKTOP_FILE"
    echo "[OK] Removed $CE_DESKTOP_FILE"
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    su - "$REAL_USER" -c "update-desktop-database \"$DESKTOP_DIR\"" 2>/dev/null || true
fi

echo
echo "Cleaning launcher user data..."

if [ -d "$GAME_LAUNCHER_DIR" ]; then
    if confirm "Remove launcher database ($GAME_LAUNCHER_DIR)?"; then
        rm -rf "$GAME_LAUNCHER_DIR"
        echo "[OK] Removed database directory."
    else
        echo "[SKIP] Kept $GAME_LAUNCHER_DIR"
    fi
fi

PREFIX_ROOT="$USER_HOME/Games/ProtonPrefixes"
if [ -d "$PREFIX_ROOT" ]; then
    echo "[SKIP] Proton prefixes left untouched at: $PREFIX_ROOT"
fi

echo "=========================================="
echo "Uninstall finished successfully."
echo "=========================================="

# Clean up temporary execution file if ran from /tmp
if [[ "$0" == "/tmp/proton-uninstall.sh" ]]; then
    rm -f /tmp/proton-uninstall.sh
fi
