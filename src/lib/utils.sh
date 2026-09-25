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
    local marker="$1" row esc_marker
    esc_marker="$(sql_escape "$marker")"
    row="$(sqlite3 -separator '|' "$DB" \
        "SELECT prefix_mode, manual_name, proton_name, cheat_engine_autoboot, mangohud, \
                window_width, window_height, window_mode
         FROM games WHERE marker_id = '$esc_marker' LIMIT 1;")"

    if [ -z "$row" ]; then
        return 1
    fi

    IFS='|' read -r PREFIX_MODE MANUAL_NAME SEL_PROTON_NAME CE_AUTOBOOT MANGOHUD \
         WINDOW_WIDTH WINDOW_HEIGHT WINDOW_MODE <<< "$row"

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


# Find game window using multiple strategies
# Strategy 1: Direct PID match
# Strategy 2: Find child processes of the given PID (for umu-launcher)
# Strategy 3: Search by window name
# Strategy 4: Search for any wine window
find_game_window() {
    local game_pid="$1"
    local game_name="$2"
    local timeout="${3:-30}"
    
    local win_id=""
    local attempts=0
    local max_attempts=$((timeout * 4))  # Check 4 times per second
    
    echo "Searching for game window (PID: $game_pid, Name: $game_name)..."
    
    while [ -z "$win_id" ] && [ $attempts -lt $max_attempts ]; do
        sleep 0.25
        ((attempts++))
        
        # Strategy 1: Direct PID match
        win_id=$(xdotool search --pid "$game_pid" 2>/dev/null | head -n1)
        
        if [ -z "$win_id" ]; then
            # Strategy 2: Find child processes of game_pid
            local child_pids
            child_pids=$(pgrep -P "$game_pid" 2>/dev/null)
            if [ -n "$child_pids" ]; then
                for child_pid in $child_pids; do
                    local child_win
                    child_win=$(xdotool search --pid "$child_pid" 2>/dev/null | head -n1)
                    if [ -n "$child_win" ]; then
                        win_id="$child_win"
                        game_pid="$child_pid"  # Update to child PID
                        break
                    fi
                done
            fi
        fi
        
        if [ -z "$win_id" ]; then
            # Strategy 3: Search by window name
            win_id=$(xdotool search --name "$game_name" 2>/dev/null | head -n1)
        fi
        
        if [ -z "$win_id" ]; then
            # Strategy 4: Search for any wine window
            win_id=$(xdotool search --class "wine" 2>/dev/null | head -n1)
        fi
        
        if [ -z "$win_id" ]; then
            # Strategy 5: Search for any window with "Game" or "Proton" in the name
            win_id=$(xdotool search --name "Game" 2>/dev/null | head -n1)
            if [ -z "$win_id" ]; then
                win_id=$(xdotool search --name "Proton" 2>/dev/null | head -n1)
            fi
        fi
    done
    
    if [ -n "$win_id" ]; then
        echo "Found game window: $win_id (PID: $game_pid)"
        echo "$win_id"
        return 0
    else
        echo "WARNING: Could not find game window after $attempts attempts"
        echo "Tried: direct PID, child processes, window name, wine class"
        return 1
    fi
}


# Apply window settings based on mode
apply_window_settings() {
    local width="$1"
    local height="$2"
    local mode="$3"
    
    # Clear any existing window settings
    unset WINE_DESKTOP
    unset WINE_DPI_SCALING
    unset WINE_FULLSCREEN
    
    case "$mode" in
        "fixed")
            # Fixed window size - use virtual desktop
            if [ -n "$width" ] && [ -n "$height" ]; then
                export WINE_DESKTOP="${width}x${height}"
                # Enable DPI scaling for better quality
                export WINE_DPI_SCALING="1"
                echo "Window settings: Fixed ${width}x${height} with DPI scaling"
            else
                # No resolution set, use a sensible default
                export WINE_DESKTOP="1024x768"
                export WINE_DPI_SCALING="1"
                echo "Window settings: Fixed mode with default 1024x768"
            fi
            ;;
        "fullscreen")
            # Force fullscreen
            export WINE_FULLSCREEN=1
            unset WINE_DESKTOP
            unset WINE_DPI_SCALING
            echo "Window settings: Fullscreen mode (WINE_FULLSCREEN=1)"
            ;;
        "maximized")
            # Force maximized window
            unset WINE_DESKTOP
            unset WINE_DPI_SCALING
            echo "Window settings: Maximized mode"
            ;;
        "resizable"|"default")
            # Resizable window - no virtual desktop, behaves like normal window
            unset WINE_DESKTOP
            unset WINE_DPI_SCALING
            unset WINE_FULLSCREEN
            echo "Window settings: Resizable mode (free scaling, normal KDE window)"
            ;;
        *)
            # Default: resizable
            unset WINE_DESKTOP
            unset WINE_DPI_SCALING
            unset WINE_FULLSCREEN
            ;;
    esac
}

# Apply window mode after game launch (for maximized/fullscreen modes)
apply_window_mode_post_launch() {
    local mode="$1"
    local game_pid="$2"
    local game_name="$3"
    
    case "$mode" in
        "maximized")
            # Wait for window to appear, then maximize it
            if command -v xdotool >/dev/null 2>&1; then
                (
                    echo "Waiting for window to maximize..."
                    local win_id
                    win_id=$(find_game_window "$game_pid" "$game_name" 10)
                    
                    if [ -n "$win_id" ]; then
                        xdotool windowstate "$win_id" maximize
                        echo "Window maximized via xdotool"
                    else
                        echo "WARNING: Could not find window to maximize"
                    fi
                ) &
            else
                echo "WARNING: xdotool not installed, cannot maximize window"
                echo "Install with: sudo pacman -S xdotool"
            fi
            ;;
        "fullscreen")
            # Try to force fullscreen
            if command -v xdotool >/dev/null 2>&1; then
                (
                    echo "Waiting for window to set fullscreen..."
                    local win_id
                    win_id=$(find_game_window "$game_pid" "$game_name" 10)
                    
                    if [ -n "$win_id" ]; then
                        # Try fullscreen first
                        xdotool windowstate "$win_id" fullscreen
                        sleep 0.5
                        # Verify it worked
                        local state
                        state=$(xdotool getwindowstate "$win_id" 2>/dev/null)
                        if [[ "$state" != *"FULLSCREEN"* ]]; then
                            # If fullscreen didn't work, try to maximize as fallback
                            xdotool windowstate "$win_id" maximize
                            echo "Window maximized (fullscreen not supported)"
                        else
                            echo "Window set to fullscreen via xdotool"
                        fi
                    else
                        echo "WARNING: Could not find window for fullscreen"
                    fi
                ) &
            else
                echo "WARNING: xdotool not installed, cannot set fullscreen"
                echo "Install with: sudo pacman -S xdotool"
            fi
            ;;
        "fixed")
            # For fixed mode, we might need to resize the window
            if [ -n "$WINDOW_WIDTH" ] && [ -n "$WINDOW_HEIGHT" ] && command -v xdotool >/dev/null 2>&1; then
                (
                    echo "Waiting for window to resize to ${WINDOW_WIDTH}x${WINDOW_HEIGHT}..."
                    local win_id
                    win_id=$(find_game_window "$game_pid" "$game_name" 10)
                    
                    if [ -n "$win_id" ]; then
                        xdotool windowsize "$win_id" "${WINDOW_WIDTH}" "${WINDOW_HEIGHT}"
                        echo "Window resized to ${WINDOW_WIDTH}x${WINDOW_HEIGHT}"
                    fi
                ) &
            fi
            ;;
    esac
}
