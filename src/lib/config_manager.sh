#!/bin/bash
# Config Manager for Proton Launcher
# Manages configuration in ~/.config/proton-launcher/

CONFIG_DIR="$HOME/.config/proton-launcher"
CONFIG_FILE="$CONFIG_DIR/config"
EXTENSIONS_FILE="$CONFIG_DIR/extensions.conf"

# Initialize config directory
init_config_dir() {
    mkdir -p "$CONFIG_DIR"
    
    # Create default config if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<'EOF'
# Proton Launcher Configuration
# This file is managed via CLI with --config flag

# Logging Directories
LOG_DIR="$HOME/.local/share/proton-launcher/logs"
GAME_LOG_DIR="$HOME/.local/share/proton-launcher/gamelogs"

# Database
DB="$HOME/.local/share/proton-launcher/games.db"

# Cheat Engine Directory
CE_DIR="$HOME/Cheat Engine"

# Where to look for Proton installations
PROTON_BASE="$HOME/.local/share/Steam/compatibilitytools.d"
STEAM_PROTON="$HOME/.local/share/Steam/steamapps/common"

# Where per-game Proton prefixes live
PREFIX_ROOT="$HOME/Games/ProtonPrefixes"

# Default settings for new games
DEFAULT_MANGOHUD=1
DEFAULT_CE_AUTOBOOT=0
EOF
        chmod 644 "$CONFIG_FILE"
    fi
    
    # Create extensions config if it doesn't exist
    if [ ! -f "$EXTENSIONS_FILE" ]; then
        cat > "$EXTENSIONS_FILE" <<'EOF'
# Custom Extensions Configuration
# Format: EXTENSION_NAME="path/to/executable"
# These will be available to launch alongside games, or to attach/launch
# standalone via the launcher's extension attach flow.

# Example:
# CHEAT_ENGINE="$HOME/Cheat Engine/Cheat Engine.exe"
# OVERLAY="$HOME/overlay/overlay.exe"

# Optional: extra directories an extension needs mounted into the Proton
# prefix when it is attached to a running game (colon-separated paths).
# Format: EXTENSION_NAME_MOUNTS="/path/one:/path/two"
#
# Example:
# OVERLAY_MOUNTS="$HOME/overlay-assets:$HOME/overlay-config"
EOF
        chmod 644 "$EXTENSIONS_FILE"
    fi
}

# Load configuration from file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # Also load extensions config
    if [ -f "$EXTENSIONS_FILE" ]; then
        source "$EXTENSIONS_FILE"
    fi
}

# Edit configuration via CLI
edit_config() {
    echo "Opening config for editing: $CONFIG_FILE"
    echo "Extensions config: $EXTENSIONS_FILE"
    
    # Use preferred editor or fall back to nano
    local editor="${EDITOR:-nano}"
    
    if command -v "$editor" >/dev/null 2>&1; then
        "$editor" "$CONFIG_FILE"
        if [ -f "$EXTENSIONS_FILE" ]; then
            "$editor" "$EXTENSIONS_FILE"
        fi
    else
        echo "No editor found. Please edit manually:"
        echo "  Config: $CONFIG_FILE"
        echo "  Extensions: $EXTENSIONS_FILE"
    fi
}

# Get extension path by name
get_extension_path() {
    local ext_name="$1"
    local value
    
    if [ -f "$EXTENSIONS_FILE" ]; then
        value=$(grep -o "^${ext_name}=\"[^\"]*\"" "$EXTENSIONS_FILE" | cut -d'"' -f2)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    return 1
}

# Get extra mount paths configured for an extension (colon-separated), if any.
# Read from a "<NAME>_MOUNTS=\"...\"" line in extensions.conf. Never fatal if
# missing - callers should treat an empty result as "no extra mounts".
get_extension_mounts() {
    local ext_name="$1"
    local value

    if [ -f "$EXTENSIONS_FILE" ]; then
        value=$(grep -o "^${ext_name}_MOUNTS=\"[^\"]*\"" "$EXTENSIONS_FILE" | cut -d'"' -f2)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi

    return 1
}

# Resolve the configured executable path for an extension name, bridging the
# special-cased CHEAT_ENGINE variable (which can come from the main config
# file instead of extensions.conf) with regular extensions.conf entries.
get_configured_extension_path() {
    local ext_name="$1"

    if [ "$ext_name" = "CHEAT_ENGINE" ]; then
        printf '%s' "${CHEAT_ENGINE:-}"
        return 0
    fi

    get_extension_path "$ext_name"
}

# Set extension path
set_extension_path() {
    local ext_name="$1"
    local ext_path="$2"
    
    # Check if extension already exists
    if grep -q "^${ext_name}=" "$EXTENSIONS_FILE" 2>/dev/null; then
        # Update existing
        sed -i "s|^${ext_name}=.*|${ext_name}=\"${ext_path}\"|" "$EXTENSIONS_FILE"
    else
        # Add new
        echo "${ext_name}=\"${ext_path}\"" >> "$EXTENSIONS_FILE"
    fi
}

# List all configured extensions
list_extensions() {
    if [ -f "$EXTENSIONS_FILE" ]; then
        grep -v "^#" "$EXTENSIONS_FILE" | grep -v "^$" | grep "="
    fi
}
