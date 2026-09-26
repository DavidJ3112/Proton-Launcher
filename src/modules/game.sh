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

    # Apply post-launch window mode (maximized, fullscreen, fixed resizing)
    apply_window_mode_post_launch "${WINDOW_MODE:-default}" "$PID" "$AUTO_NAME"

    # Launch extensions if enabled
    launch_enabled_extensions "$marker_id"

    # Wait for game to finish
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
         window_width, window_height, window_mode)
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

# Launch enabled extensions (auto-launch alongside the game that is starting)
launch_enabled_extensions() {
    local marker_id="$1"
    
    for ext_name in "${!EXTENSIONS_ENABLED[@]}"; do
        local enabled="${EXTENSIONS_ENABLED[$ext_name]:-0}"
        if [ "$enabled" -eq 1 ]; then
            local ext_path
            # Try to get extension path - if it doesn't exist, skip silently
            if ext_path=$(get_configured_extension_path "$ext_name" 2>/dev/null) && [ -n "$ext_path" ]; then
                launch_extension "$ext_name" "$ext_path" "$marker_id"
            else
                echo "WARNING: Extension '$ext_name' not found, skipping"
            fi
        fi
    done
}

# Launch a specific extension alongside the currently-starting game
launch_extension() {
    local ext_name="$1"
    local ext_path="$2"
    local marker_id="$3"
    
    # Get running game info for this marker
    local row
    row=$(sqlite3 -separator '|' "$DB" \
        "SELECT prefix, proton_path FROM running_games WHERE marker_id = '$(sql_escape "$marker_id")' LIMIT 1;")
    
    if [ -z "$row" ]; then
        echo "WARNING: No running game found for extension $ext_name"
        return 1
    fi
    
    IFS='|' read -r game_prefix game_proton_path <<< "$row"

    # Resolve architecture-specific variant (e.g. a 64-bit build sitting next
    # to the configured executable) based on the game we're launching alongside.
    local final_ext_path
    final_ext_path="$(resolve_extension_binary "$ext_path" "$IS_32BIT")"

    if [ ! -f "$final_ext_path" ]; then
        echo "WARNING: Extension '$ext_name' path does not exist: $final_ext_path"
        return 1
    fi

    echo "Launching extension: $ext_name ($final_ext_path)"

    export WINEPREFIX="$game_prefix"
    export PROTONPATH="$game_proton_path"
    export PROTON_VERB="runinprefix"
    export STEAM_COMPAT_LIBRARY_PATHS="/home"

    local mounts
    if mounts="$(get_extension_mounts "$ext_name" 2>/dev/null)" && [ -n "$mounts" ]; then
        export STEAM_COMPAT_MOUNTS="$mounts"
        echo "  Extra mounts: $mounts"
    else
        unset STEAM_COMPAT_MOUNTS
    fi

    umu-run "$final_ext_path" &
}

# ======================================================================
# Extension Attach / Standalone Launch Pipeline
#
# This implements the flow for launching an extension binary directly
# (e.g. running the launcher against Cheat Engine.exe, or any other
# executable configured in extensions.conf), as opposed to launching a
# normal game:
#
#   F1  check_extension_target      - is the requested executable itself
#                                      a configured extension?
#   F2  prompt_attach_or_standalone - ask the user: attach to a running
#                                      game, or boot standalone?
#   F3  pick_running_game_for_attach - let the user choose which running
#                                      game to attach to
#   F4  gather_attach_mounts        - pull the target game's prefix/proton
#                                      data (already fetched in F3) and any
#                                      extra mounts the extension needs
#   F5  launch_attached_extension   - actually launch it
#
# IMPORTANT: none of this ever writes to the `games` or `game_extensions`
# tables. Extensions are never persisted as if they were games.
# ======================================================================

# F1: Determine whether $1 (an already realpath'd executable) matches a
# configured extension. On match, sets EXT_NAME / EXT_PATH and returns 0.
check_extension_target() {
    local exe_path="$1"
    EXT_NAME=""
    EXT_PATH=""

    local name path resolved

    # Pass 1: exact path match (preferred, unambiguous)
    for name in $AVAILABLE_EXTENSIONS; do
        path="$(get_configured_extension_path "$name")"
        [ -z "$path" ] && continue
        resolved="$(realpath -m "$path" 2>/dev/null)"
        [ -z "$resolved" ] && continue
        if [ "$exe_path" = "$resolved" ]; then
            EXT_NAME="$name"
            EXT_PATH="$resolved"
            return 0
        fi
    done

    # Pass 2: same-directory fallback. Handles cases like a 32/64-bit build
    # of the same tool sitting next to the configured executable.
    for name in $AVAILABLE_EXTENSIONS; do
        path="$(get_configured_extension_path "$name")"
        [ -z "$path" ] && continue
        resolved="$(realpath -m "$path" 2>/dev/null)"
        [ -z "$resolved" ] && continue
        if [ "$(dirname "$exe_path")" = "$(dirname "$resolved")" ]; then
            EXT_NAME="$name"
            EXT_PATH="$resolved"
            return 0
        fi
    done

    return 1
}

# F2: Ask the user whether they want to attach this extension to a running
# game, or boot it standalone. Prints "attached", "standalone" or "cancel".
prompt_attach_or_standalone() {
    local pick
    if command -v rofi >/dev/null 2>&1; then
        pick="$(printf '%s\n' "Attached Boot (attach to a running game)" "Standalone Boot" "Cancel" | \
            rofi -dmenu -i -p "$EXT_NAME: launch mode")"
    else
        # NOTE: this function's output is captured via $(...), so anything
        # printed to stdout here would corrupt the returned mode. All
        # prompt/menu text must go to stderr.
        {
            echo "Launch mode for $EXT_NAME:"
            echo "  1. Attached Boot (attach to a running game)"
            echo "  2. Standalone Boot"
            echo "  3. Cancel"
        } >&2
        read -r -p "Select option: " pick
    fi

    case "$pick" in
        "Attached Boot"*|1) echo "attached" ;;
        "Standalone Boot"*|2) echo "standalone" ;;
        *) echo "cancel" ;;
    esac
}

# F3 + F4: Let the user pick a currently running game from the database and
# pull its prefix/proton/32-bit data. On success, sets:
#   ATTACH_MARKER, ATTACH_NAME, ATTACH_PREFIX, ATTACH_PROTON,
#   ATTACH_PROTON_PATH, ATTACH_GAME_PATH, ATTACH_IS_32BIT
pick_running_game_for_attach() {
    local running
    running="$(sqlite3 -separator '|' "$DB" \
        "SELECT rg.marker_id, rg.game_name, rg.prefix, rg.proton, rg.proton_path,
                rg.game_path, COALESCE(g.is_32bit, 0)
         FROM running_games rg
         LEFT JOIN games g ON g.marker_id = rg.marker_id
         ORDER BY rg.started_at DESC;")"

    if [ -z "$running" ]; then
        display_error "No games are currently running to attach ${EXT_NAME} to."
        return 1
    fi

    local -a labels rows
    local line r_gpath folder exe
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        r_gpath="$(printf '%s' "$line" | awk -F'|' '{print $6}')"
        folder="$(basename "$(dirname "$r_gpath")")"
        exe="$(basename "$r_gpath")"
        labels+=("[$folder] $exe")
        rows+=("$line")
    done <<< "$running"

    local choice idx=-1 i
    if command -v rofi >/dev/null 2>&1; then
        choice="$(printf '%s\n' "${labels[@]}" | rofi -dmenu -i -p "Attach ${EXT_NAME} to")"
    else
        echo "Currently running games:"
        for i in "${!labels[@]}"; do
            echo "  $((i+1)). ${labels[$i]}"
        done
        read -r -p "Select number: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#labels[@]}" ]; then
            idx=$((choice - 1))
        fi
    fi

    [ -z "$choice" ] && return 1

    if [ "$idx" -lt 0 ]; then
        for i in "${!labels[@]}"; do
            if [ "${labels[$i]}" = "$choice" ]; then
                idx=$i
                break
            fi
        done
    fi

    [ "$idx" -lt 0 ] && return 1

    IFS='|' read -r ATTACH_MARKER ATTACH_NAME ATTACH_PREFIX ATTACH_PROTON \
        ATTACH_PROTON_PATH ATTACH_GAME_PATH ATTACH_IS_32BIT <<< "${rows[$idx]}"

    return 0
}

# F4 (mounts half): populate ATTACH_MOUNTS from extensions.conf, if configured.
gather_attach_mounts() {
    ATTACH_MOUNTS=""
    local mounts
    if mounts="$(get_extension_mounts "$EXT_NAME" 2>/dev/null)" && [ -n "$mounts" ]; then
        ATTACH_MOUNTS="$mounts"
    fi
}

# F5: Launch the extension attached to the previously selected running game.
launch_attached_extension() {
    local binary
    binary="$(resolve_extension_binary "$EXT_PATH" "$ATTACH_IS_32BIT")"

    if [ ! -f "$binary" ]; then
        display_error "Extension executable not found:\n$binary"
        exit 1
    fi

    export WINEPREFIX="$ATTACH_PREFIX"
    export PROTONPATH="$ATTACH_PROTON_PATH"
    export PROTON_VERB="runinprefix"
    export STEAM_COMPAT_LIBRARY_PATHS="/home"

    if [ -n "$ATTACH_MOUNTS" ]; then
        export STEAM_COMPAT_MOUNTS="$ATTACH_MOUNTS"
    else
        unset STEAM_COMPAT_MOUNTS
    fi

    echo "Attaching $EXT_NAME to '$ATTACH_NAME' (marker: $ATTACH_MARKER)"
    echo "  Executable: $binary"
    echo "  Prefix:     $ATTACH_PREFIX"
    echo "  Proton:     $ATTACH_PROTON"
    [ -n "$ATTACH_MOUNTS" ] && echo "  Extra mounts: $ATTACH_MOUNTS"

    umu-run "$binary"
    local exit_code=$?
    echo "$EXT_NAME exited with code: $exit_code"
    exit "$exit_code"
}

# Standalone boot: run the extension on its own, dedicated Proton prefix,
# without attaching to any running game. Mirrors what standalone Cheat
# Engine used to do, generalized to any extension. Never touches the
# `games` table.
launch_extension_standalone() {
    echo "$EXT_NAME standalone execution mode requested."

    local prefix="${PREFIX_ROOT:-$HOME/Games/ProtonPrefixes}/${EXT_NAME}"
    mkdir -p "$prefix"

    discover_protons
    local default_proton
    default_proton="$(sqlite3 "$DB" "SELECT path FROM protons WHERE status='active' ORDER BY name LIMIT 1;")"
    if [ -z "$default_proton" ]; then
        display_error "No active Proton installation found. Cannot launch $EXT_NAME."
        exit 1
    fi

    if [ ! -f "$EXT_PATH" ]; then
        display_error "Extension executable not found:\n$EXT_PATH"
        exit 1
    fi

    export WINEPREFIX="$prefix"
    export PROTONPATH="$default_proton"
    export PROTON_VERB="runinprefix"
    export STEAM_COMPAT_LIBRARY_PATHS="/home"

    local mounts
    if mounts="$(get_extension_mounts "$EXT_NAME" 2>/dev/null)" && [ -n "$mounts" ]; then
        export STEAM_COMPAT_MOUNTS="$mounts"
    else
        unset STEAM_COMPAT_MOUNTS
    fi

    echo "Launching $EXT_NAME standalone: $EXT_PATH"
    echo "  Prefix: $prefix"
    echo "  Proton: $default_proton"
    [ -n "$mounts" ] && echo "  Extra mounts: $mounts"

    umu-run "$EXT_PATH"
    local exit_code=$?
    echo "$EXT_NAME exited with code: $exit_code"
    exit "$exit_code"
}

# Orchestrator for the whole pipeline. Call this with the resolved executable
# path the user asked to launch. If it's not a configured extension, this
# returns 1 so the caller proceeds with normal game boot. Every branch that
# *does* match an extension exits the process itself (it never returns).
handle_extension_launch() {
    local exe_path="$1"

    # F1
    if ! check_extension_target "$exe_path"; then
        return 1
    fi

    echo "Detected extension launch target: $EXT_NAME ($EXT_PATH)"

    # F2
    local mode
    mode="$(prompt_attach_or_standalone)"

    case "$mode" in
        attached)
            # F3
            if ! pick_running_game_for_attach; then
                echo "No running game selected/available for $EXT_NAME attach; exiting."
                exit 0
            fi
            # F4
            gather_attach_mounts
            # F5
            launch_attached_extension
            ;;
        standalone)
            launch_extension_standalone
            ;;
        *)
            echo "Cancelled by user."
            exit 0
            ;;
    esac
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
    export GAME
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
