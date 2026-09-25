#!/bin/bash
# Utility Functions for Proton Launcher

# Generate UUID
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        echo "$(date +%s%N)-$RANDOM"
    fi
}

# Get marker ID for a game directory
get_marker_id() {
    local game_dir="$1"
    local marker="$game_dir/.proton-launcher-id"

    if [ -f "$marker" ]; then
        cat "$marker"
        return
    fi

    local id
    id="$(gen_uuid)"
    if echo "$id" > "$marker" 2>/dev/null; then
        echo "$id"
    else
        echo "WARNING: could not write marker file in $game_dir (read-only?)." >&2
        echo "path:$game_dir"
    fi
}

# Check if game is 32-bit
check_32bit() {
    local game_path="$1"
    if [ -f "$game_path" ] && file -b "$game_path" | grep -q "PE32 "; then
        return 0
    fi
    return 1
}

# Show 32-bit warning
check_32bit_warning() {
    if [ -n "${GAME:-}" ] && [ -f "$GAME" ]; then
        if check_32bit "$GAME"; then
            local game_basename
            game_basename="$(basename "$GAME")"
            echo "NOTICE: $game_basename is a 32-bit executable."
            if command -v rofi >/dev/null 2>&1; then
                rofi -e "\u26a0\ufe0f  32-Bit Game Detected: $game_basename

Features enabled for stability:
\u2022 WINEARCH forced to win32 mode.
\u2022 PROTON_FORCE_LARGE_ADDRESS_AWARE enabled.
\u2022 Auto-cleanup on close enabled to prevent hung wine processes."
            fi
        fi
    fi
}

# Discover available Proton installations
discover_protons() {
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"

    shopt -s nullglob
    local dir name esc_name esc_path
    for dir in "$PROTON_BASE"/*/ "$STEAM_PROTON"/*/; do
        [ -d "$dir" ] || continue
        dir="${dir%/}"
        name="$(basename "$dir")"
        case "$name" in
            *[Pp]roton*) ;;
            *) continue ;;
        esac

        esc_name="$(sql_escape "$name")"
        esc_path="$(sql_escape "$dir")"
        sqlite3 "$DB" "INSERT INTO protons (name, path, status, last_seen)
            VALUES ('$esc_name', '$esc_path', 'active', '$now')
            ON CONFLICT(name) DO UPDATE SET
                path='$esc_path', status='active', last_seen='$now';"
    done
    shopt -u nullglob

    local rows path
    rows="$(sqlite3 -separator '|' "$DB" "SELECT name, path FROM protons;")"
    while IFS='|' read -r name path; do
        [ -z "$name" ] && continue
        if [ ! -d "$path" ]; then
            esc_name="$(sql_escape "$name")"
            sqlite3 "$DB" "UPDATE protons SET status='missing' WHERE name = '$esc_name';"
        fi
    done <<< "$rows"
}

# Get list of active protons
get_active_protons() {
    sqlite3 -separator '|' "$DB" "SELECT name, path FROM protons WHERE status='active' ORDER BY name;"
}

# Get list of missing protons
get_missing_protons() {
    sqlite3 -separator '|' "$DB" "SELECT name, path FROM protons WHERE status='missing' ORDER BY name;"
}

# Clean up stale running games entries
cleanup_stale_running() {
    local rows marker pid esc_marker
    rows="$(sqlite3 -separator '|' "$DB" "SELECT marker_id, pid FROM running_games;")"
    while IFS='|' read -r marker pid; do
        [ -z "$marker" ] && continue
        if ! kill -0 "$pid" 2>/dev/null; then
            esc_marker="$(sql_escape "$marker")"
            sqlite3 "$DB" "DELETE FROM running_games WHERE marker_id = '$esc_marker';"
        fi
    done <<< "$rows"
}

# Load game configuration from database
load_game_config() {
    local marker="$1"
    local row esc_marker
    esc_marker="$(sql_escape "$marker")"
    row="$(sqlite3 -separator '|' "$DB" \
        "SELECT prefix_mode, manual_name, proton_name, cheat_engine_autoboot, mangohud, \
                mute_on_focus_loss, window_width, window_height, window_scaling
         FROM games WHERE marker_id = '$esc_marker' LIMIT 1;")"

    if [ -z "$row" ]; then
        return 1
    fi

    IFS='|' read -r PREFIX_MODE MANUAL_NAME SEL_PROTON_NAME CE_AUTOBOOT MANGOHUD \
         MUTE_ON_FOCUS_LOSS WINDOW_WIDTH WINDOW_HEIGHT WINDOW_SCALING <<< "$row"

    if [ -n "$SEL_PROTON_NAME" ]; then
        SEL_PROTON_PATH="$(sqlite3 "$DB" \
            "SELECT path FROM protons WHERE name = '$(sql_escape "$SEL_PROTON_NAME")' LIMIT 1;")"
    else
        SEL_PROTON_PATH=""
    fi

    return 0
}

# Get all extensions for a game
get_game_extensions() {
    local marker="$1"
    local esc_marker
    esc_marker="$(sql_escape "$marker")"
    
    sqlite3 -separator '|' "$DB" \
        "SELECT extension_name, enabled FROM game_extensions WHERE marker_id = '$esc_marker';"
}

# Save game extensions
save_game_extensions() {
    local marker="$1"
    local esc_marker
    esc_marker="$(sql_escape "$marker")"
    
    # Clear existing extensions for this game
    sqlite3 "$DB" "DELETE FROM game_extensions WHERE marker_id = '$esc_marker';"
    
    # Save new extensions
    for ext_name in "${!EXTENSIONS_ENABLED[@]}"; do
        local enabled="${EXTENSIONS_ENABLED[$ext_name]:-0}"
        sqlite3 "$DB" \
            "INSERT INTO game_extensions (marker_id, extension_name, enabled) \
             VALUES ('$esc_marker', '$(sql_escape "$ext_name")', $enabled);"
    done
}

# Get window geometry string for WINE
get_window_geometry() {
    local width="$1"
    local height="$2"
    local scaling="$3"
    
    if [ -n "$width" ] && [ -n "$height" ]; then
        if [ "$scaling" -eq 1 ]; then
            echo "${width}x${height}"
        else
            # For non-scaling, use virtual desktop
            echo "${width}x${height}"
        fi
    fi
}

# Get Cheat Engine executable path
get_cheat_engine_exe() {
    local ce_dir
    ce_dir="$(dirname "${CHEAT_ENGINE:-$HOME/Cheat Engine/Cheat Engine.exe}")"

    if [ "$(uname -m)" = "x86_64" ] && [ -f "$ce_dir/cheatengine-x86_64.exe" ]; then
        echo "$ce_dir/cheatengine-x86_64.exe"
    elif [ -f "$ce_dir/Cheat Engine.exe" ]; then
        echo "$ce_dir/Cheat Engine.exe"
    else
        echo "${CHEAT_ENGINE:-}"
    fi
}

# Get Cheat Engine executable path
get_cheat_engine_exe() {
    local ce_dir
    ce_dir="$(dirname "${CHEAT_ENGINE:-$HOME/Cheat Engine/Cheat Engine.exe}")"

    if [ "$(uname -m)" = "x86_64" ] && [ -f "$ce_dir/cheatengine-x86_64.exe" ]; then
        echo "$ce_dir/cheatengine-x86_64.exe"
    elif [ -f "$ce_dir/Cheat Engine.exe" ]; then
        echo "$ce_dir/Cheat Engine.exe"
    else
        echo "${CHEAT_ENGINE:-}"
    fi
}

# Apply window settings as environment variables
apply_window_settings() {
    local width="$1"
    local height="$2"
    local scaling="$3"
    
    if [ -n "$width" ] && [ -n "$height" ]; then
        export WINE_DESKTOP="${width}x${height}"
        
        if [ "$scaling" -eq 1 ]; then
            # Enable DPI scaling
            export WINE_DPI_SCALING="1"
        else
            # Disable scaling, use exact resolution
            export WINE_DPI_SCALING="0"
        fi
        
        echo "Window settings applied: ${width}x${height}, scaling=$scaling"
    fi
}
