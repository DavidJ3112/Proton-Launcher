#!/bin/bash
# Game Module for Proton Launcher
# Handles game discovery, launching, and management

# Launch game with selected configuration
launch_game() {
    local game_path="$1"
    local marker_id="$2"
    
    case "$PREFIX_MODE" in
        auto)      PREFIX_NAME="$AUTO_NAME" ;;
        directory) PREFIX_NAME="$DIR_NAME" ;;
        manual)    PREFIX_NAME="${MANUAL_NAME:-$AUTO_NAME}" ;;
        *)         PREFIX_NAME="$AUTO_NAME" ;;
    esac

    PREFIX="${PREFIX_ROOT:-$HOME/Games/ProtonPrefixes}/$PREFIX_NAME"
    mkdir -p "$PREFIX"

    # Persist configured options
    persist_game_config "$marker_id"

    export WINEPREFIX="$PREFIX"
    export PROTONPATH="$SEL_PROTON_PATH"
    export WINEDLLOVERRIDES="winhttp.dll=n,b;winegstreamer="
    export PROTON_ENABLE_WAYLAND=0
    export WINEDEBUG="+err,+warn,+module"
    export PROTON_LOG=1
    export PROTON_LOG_DIR="${LOG_DIR:-$HOME/.local/share/proton-launcher/logs}"

    # Game log handling
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    GAME_LOG="${GAME_LOG_DIR:-$HOME/.local/share/proton-launcher/gamelogs}/${AUTO_NAME}_${timestamp}.log"

    # Clean up old game logs (keep max 2)
    cleanup_game_logs

    # 32-Bit Execution Enhancements
    if [ "$IS_32BIT" -eq 1 ]; then
        echo "Applying 32-bit execution environment settings..."
        export WINEARCH="win32"
        export PROTON_FORCE_LARGE_ADDRESS_AWARE=1
    fi

    # Apply window settings based on mode
    apply_window_settings "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "${WINDOW_MODE:-default}"

    # Apply mute on focus loss
    if [ "${MUTE_ON_FOCUS_LOSS:-0}" -eq 1 ]; then
        export PULSE_PROP="media.role=game"
        export PROTON_MUTE_ON_FOCUS_LOSS=1
        echo "Mute on focus loss enabled"
    fi

    echo "Launching game..."
    echo "  Game:     $AUTO_NAME"
    echo "  32-Bit:   $IS_32BIT"
    echo "  Proton:   $SEL_PROTON_NAME"
    echo "  Prefix:   $PREFIX"
    echo "  Window:   ${WINDOW_MODE:-default}"
    if [ "${WINDOW_MODE:-default}" = "fixed" ] && [ -n "$WINDOW_WIDTH" ] && [ -n "$WINDOW_HEIGHT" ]; then
        echo "  Resolution: ${WINDOW_WIDTH}x${WINDOW_HEIGHT}"
    fi
    echo "  Game Log: $GAME_LOG"

    # Launch game
    if [ "$MANGOHUD" = "1" ]; then
        MANGOHUD=1 umu-run "$game_path" > >(tee -a "$GAME_LOG") 2>&1 &
    else
        umu-run "$game_path" > >(tee -a "$GAME_LOG") 2>&1 &
    fi
    PID=$!

    # Register running game
    register_running_game "$marker_id" "$game_path" "$PID"

    # Launch extensions if enabled
    launch_enabled_extensions "$marker_id"

    wait "$PID"
    local exit_code=$?

    # Clean up running game entry
    sqlite3 "$DB" "DELETE FROM running_games WHERE marker_id = '$(sql_escape "$marker_id")';"

    # Clean orphaned Wine processes if 32-bit app fails to close completely
    if [ "$IS_32BIT" -eq 1 ]; then
        echo "Cleaning up residual 32-bit processes..."
        wineserver -k 2>/dev/null || true
    fi

    echo "Exited with code: $exit_code"
    exit "$exit_code"
}

# Persist game configuration to database
persist_game_config() {
    local marker_id="$1"
    
    sqlite3 "$DB" "INSERT INTO games
        (marker_id, name, prefix_mode, manual_name, proton_name,
         cheat_engine_autoboot, mangohud, is_32bit, last_path, last_launched,
         mute_on_focus_loss, window_width, window_height, window_mode)
        VALUES
        ('$(sql_escape "$marker_id")',
         '$(sql_escape "$AUTO_NAME")',
         '$(sql_escape "$PREFIX_MODE")',
         '$(sql_escape "$MANUAL_NAME")',
         '$(sql_escape "$SEL_PROTON_NAME")',
         $CE_AUTOBOOT,
         $MANGOHUD,
         $IS_32BIT,
         '$(sql_escape "$GAME")',
         datetime('now'),
         ${MUTE_ON_FOCUS_LOSS:-0},
         ${WINDOW_WIDTH:-NULL},
         ${WINDOW_HEIGHT:-NULL},
         '$(sql_escape "${WINDOW_MODE:-default}")')
        ON CONFLICT(marker_id) DO UPDATE SET
            name='$(sql_escape "$AUTO_NAME")',
            prefix_mode='$(sql_escape "$PREFIX_MODE")',
            manual_name='$(sql_escape "$MANUAL_NAME")',
            proton_name='$(sql_escape "$SEL_PROTON_NAME")',
            cheat_engine_autoboot=$CE_AUTOBOOT,
            mangohud=$MANGOHUD,
            is_32bit=$IS_32BIT,
            last_path='$(sql_escape "$GAME")',
            last_launched=datetime('now'),
            mute_on_focus_loss=${MUTE_ON_FOCUS_LOSS:-0},
            window_width=${WINDOW_WIDTH:-NULL},
            window_height=${WINDOW_HEIGHT:-NULL},
            window_mode='$(sql_escape "${WINDOW_MODE:-default}")';"
    
    # Save extensions
    save_game_extensions "$marker_id"
}

# Register running game in database
register_running_game() {
    local marker_id="$1"
    local game_path="$2"
    local pid="$3"
    
    sqlite3 "$DB" "INSERT OR REPLACE INTO running_games
        (marker_id, game_name, game_path, pid, proton, proton_path, prefix, started_at)
        VALUES
        ('$(sql_escape "$marker_id")',
         '$(sql_escape "$AUTO_NAME")',
         '$(sql_escape "$game_path")',
         $pid,
         '$(sql_escape "$SEL_PROTON_NAME")',
         '$(sql_escape "$SEL_PROTON_PATH")',
         '$(sql_escape "$PREFIX")',
         datetime('now'));"
}

# Clean up old game logs
cleanup_game_logs() {
    shopt -s nullglob
    local old_logs=("${GAME_LOG_DIR:-$HOME/.local/share/proton-launcher/gamelogs}/${AUTO_NAME}_"*.log)
    shopt -u nullglob

    if [ "${#old_logs[@]}" -ge 2 ]; then
        mapfile -t sorted_logs < <(printf '%s\n' "${old_logs[@]}" | sort)
        local remove_count=$(( ${#sorted_logs[@]} - 1 ))
        for (( i=0; i<remove_count; i++ )); do
            rm -f "${sorted_logs[i]}"
        done
    fi
}

# Launch enabled extensions
launch_enabled_extensions() {
    local marker_id="$1"
    
    for ext_name in "${!EXTENSIONS_ENABLED[@]}"; do
        local enabled="${EXTENSIONS_ENABLED[$ext_name]:-0}"
        if [ "$enabled" -eq 1 ]; then
            local ext_path
            # Try to get extension path - if it doesn't exist, skip silently
            if ext_path=$(get_extension_path "$ext_name" 2>/dev/null); then
                launch_extension "$ext_name" "$ext_path" "$marker_id"
            else
                echo "WARNING: Extension '$ext_name' not found, skipping"
            fi
        fi
    done
}

# Launch a specific extension
launch_extension() {
    local ext_name="$1"
    local ext_path="$2"
    local marker_id="$3"
    
    # Check if extension file exists
    if [ ! -f "$ext_path" ]; then
        echo "WARNING: Extension '$ext_name' path does not exist: $ext_path"
        return 1
    fi
    
    echo "Launching extension: $ext_name ($ext_path)"
    
    # Get running game info for this marker
    local row
    row=$(sqlite3 -separator '|' "$DB" \
        "SELECT prefix, proton_path FROM running_games WHERE marker_id = '$(sql_escape "$marker_id")' LIMIT 1;")
    
    if [ -z "$row" ]; then
        echo "WARNING: No running game found for extension $ext_name"
        return 1
    fi
    
    IFS='|' read -r game_prefix game_proton_path <<< "$row"
    
    export WINEPREFIX="$game_prefix"
    export PROTONPATH="$game_proton_path"
    export PROTON_VERB="runinprefix"
    export STEAM_COMPAT_LIBRARY_PATHS="/home"
    
    # Handle architecture-specific extensions
    local final_ext_path="$ext_path"
    if [ "$ext_name" = "CHEAT_ENGINE" ] && [ "$IS_32BIT" -eq 1 ]; then
        local ce_dir
        ce_dir=$(dirname "$ext_path")
        if [ -f "$ce_dir/cheatengine-x86_64.exe" ]; then
            final_ext_path="$ce_dir/cheatengine-x86_64.exe"
        fi
    fi
    
    umu-run "$final_ext_path" &
}

# Select game from previously run games
select_game() {
    echo "No executable specified. Fetching previously run games..."

    local saved_games
    saved_games="$(sqlite3 -separator '|' "$DB" \
        "SELECT last_path FROM games WHERE last_path IS NOT NULL AND last_path != '' GROUP BY last_path ORDER BY last_launched DESC;")"

    if [ -z "$saved_games" ]; then
        if command -v rofi >/dev/null 2>&1; then
            rofi -e "No previously played games found in database."
        fi
        exit 0
    fi

    # Format output for Rofi: "[Folder Name] Executable.exe"
    local formatted_list=""
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        local folder exe
        folder="$(basename "$(dirname "$path")")"
        exe="$(basename "$path")"
        formatted_list="${formatted_list}[$folder] $exe|$path\n"
    done <<< "$saved_games"

    local selected_display
    if command -v rofi >/dev/null 2>&1; then
        selected_display="$(printf "%b" "$formatted_list" | cut -d'|' -f1 | rofi -dmenu -i -p "Select Game")"
    else
        echo "Available games:"
        echo "$formatted_list"
        read -r -p "Enter game path: " selected_display
    fi

    if [ -z "$selected_display" ]; then
        exit 0
    fi

    GAME="$(printf "%b" "$formatted_list" | grep "^${selected_display}|" | cut -d'|' -f2 | head -n1)"
}

# Handle Cheat Engine standalone mode (legacy support)
handle_cheat_engine_mode() {
    local ce_base_dir
    ce_base_dir="$(dirname "${CHEAT_ENGINE:-$HOME/Cheat Engine/Cheat Engine.exe}")"
    
    if [ -n "${CHEAT_ENGINE:-}" ] && { [ "$GAME" = "$CHEAT_ENGINE" ] || [ "$GAME" = "$ce_base_dir/Cheat Engine.exe" ] || [ "$GAME" = "$ce_base_dir/cheatengine-x86_64.exe" ]; }; then
        echo "Cheat Engine execution mode requested."

        local running
        running="$(sqlite3 -separator '|' "$DB" \
            "SELECT marker_id, game_name, prefix, proton, proton_path, game_path
             FROM running_games
             ORDER BY started_at DESC;")"

        if [ -z "$running" ]; then
            if command -v rofi >/dev/null 2>&1; then
                rofi -e "No games are currently running to attach Cheat Engine to."
            fi
            exit 0
        fi

        # Format running games list
        local ce_list=""
        while IFS='|' read -r r_marker r_name r_prefix r_proton r_p_path r_gpath; do
            [ -z "$r_marker" ] && continue
            local r_folder r_exe
            r_folder="$(basename "$(dirname "$r_gpath")")"
            r_exe="$(basename "$r_gpath")"
            ce_list="${ce_list}[$r_folder] $r_exe|$r_marker\n"
        done <<< "$running"

        local pick_display
        if command -v rofi >/dev/null 2>&1; then
            pick_display="$(printf "%b" "$ce_list" | cut -d'|' -f1 | rofi -dmenu -i -p "Attach Cheat Engine to")"
        else
            echo "Running games:"
            echo "$ce_list"
            read -r -p "Select game marker: " pick_display
        fi

        if [ -z "$pick_display" ]; then
            exit 0
        fi

        local selected_marker
        selected_marker="$(printf "%b" "$ce_list" | grep "^${pick_display}|" | cut -d'|' -f2 | head -n1)"
        local row
        row="$(printf '%s\n' "$running" | grep "^${selected_marker}|" | head -n1)"
        IFS='|' read -r R_MARKER R_NAME R_PREFIX R_PROTON R_PROTON_PATH R_GPATH <<< "$row"

        export WINEPREFIX="$R_PREFIX"
        export PROTONPATH="$R_PROTON_PATH"
        export PROTON_VERB="runinprefix"
        export STEAM_COMPAT_LIBRARY_PATHS="/home"

        local is_game_32bit
        is_game_32bit="$(sqlite3 "$DB" "SELECT is_32bit FROM games WHERE marker_id = '$(sql_escape "$R_MARKER")' LIMIT 1;")"

        local ce_exec="$ce_base_dir/Cheat Engine.exe"
        if [ "$is_game_32bit" != "1" ] && [ -f "$ce_base_dir/cheatengine-x86_64.exe" ]; then
            ce_exec="$ce_base_dir/cheatengine-x86_64.exe"
        fi

        echo "Launching Cheat Engine executable: $ce_exec"
        umu-run "$ce_exec"
        local exit_code=$?
        exit "$exit_code"
    fi
}

# Show extensions configuration menu
show_extensions_menu() {
    local menu_lines=("Back")
    
    # Add all available extensions
    for ext in $AVAILABLE_EXTENSIONS; do
        local ext_enabled="${EXTENSIONS_ENABLED[$ext]:-0}"
        menu_lines+=("$ext: $([ "$ext_enabled" = "1" ] && echo On || echo Off)")
    done
    
    while true; do
        local choice
        if command -v rofi >/dev/null 2>&1; then
            choice="$(printf '%s\n' "${menu_lines[@]}" | rofi -dmenu -i -p "Extensions")"
        else
            echo "Extensions:"
            for i in "${!menu_lines[@]}"; do
                echo "  $((i+1)). ${menu_lines[$i]}"
            done
            read -r -p "Select option (number or name): " choice
        fi
        
        [ -z "$choice" ] && return
        
        case "$choice" in
            "Back")
                return
                ;;
            *)
                # Check if it's an extension toggle
                for ext in $AVAILABLE_EXTENSIONS; do
                    if [[ "$choice" == "$ext:"* ]]; then
                        EXTENSIONS_ENABLED[$ext]=$([ "${EXTENSIONS_ENABLED[$ext]:-0}" = "1" ] && echo 0 || echo 1)
                        break
                    fi
                done
                ;;
        esac
    done
}
