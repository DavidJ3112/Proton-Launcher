#!/bin/bash

set -u

# Ensure script is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run setup.sh as root/sudo to install to /opt."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config"
LAUNCHER="$SCRIPT_DIR/proton-launcher"

INSTALL_DIR="/opt/proton-launcher"
BIN_LINK="/usr/local/bin/proton-launcher"
DESKTOP_DIR="$USER_HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/proton-launcher.desktop"
CE_DESKTOP_FILE="$DESKTOP_DIR/proton-launcher-ce.desktop"

echo "=========================================="
echo "        Proton Launcher Setup (/opt)"
echo "=========================================="
echo

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file not found at $CONFIG"
    exit 1
fi

source "$CONFIG"
echo "[OK] Configuration loaded"

# Install files to /opt/proton-launcher
echo "Installing files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR/"

# Ensure correct execution permissions
chmod +x "$INSTALL_DIR/proton-launcher"
chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR/uninstall.sh"

# Create symlink in system PATH
ln -sf "$INSTALL_DIR/proton-launcher" "$BIN_LINK"
echo "[OK] Created symlink at $BIN_LINK"

# Ensure user runtime directories exist
su - "$REAL_USER" -c "mkdir -p \"$USER_HOME/.local/share/proton-launcher\" \"${PREFIX_ROOT:-$USER_HOME/Games/ProtonPrefixes}\" \"$DESKTOP_DIR\" \"$USER_HOME/.config/proton-launcher\""

# Create Proton Launcher desktop entry
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Proton Launcher
Comment=Launch Windows games with Proton or choose from library
Exec=$BIN_LINK %f
Icon=applications-games
Terminal=false
Type=Application
Categories=Game;
MimeType=application/x-ms-dos-executable;
EOF

chown "$REAL_USER:$REAL_USER" "$DESKTOP_FILE"
chmod 644 "$DESKTOP_FILE"

# Create Cheat Engine shortcut desktop entry
cat > "$CE_DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Proton Launcher - Cheat Engine
Comment=Attach Cheat Engine to a running Proton game prefix
Exec=$BIN_LINK "$CHEAT_ENGINE"
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Game;Utility;
EOF

chown "$REAL_USER:$REAL_USER" "$CE_DESKTOP_FILE"
chmod 644 "$CE_DESKTOP_FILE"

if command -v update-desktop-database >/dev/null 2>&1; then
    su - "$REAL_USER" -c "update-desktop-database \"$DESKTOP_DIR\"" 2>/dev/null || true
fi

echo "=========================================="
echo "Setup completed successfully."
echo "Installed location: $INSTALL_DIR"
echo "Created shortcuts:"
echo " - $DESKTOP_FILE"
echo " - $CE_DESKTOP_FILE"
echo "=========================================="
