#!/bin/bash
# UI Module for Proton Launcher
# Handles user interface interactions

# Pick window scaling mode
pick_window_scaling() {
    local current_scaling="${WINDOW_SCALING:-0}"
    local current_width="${WINDOW_WIDTH:-}"
    local current_height="${WINDOW_HEIGHT:-}"
    
    local scaling_label
    if [ "$current_scaling" -eq 1 ]; then
        scaling_label="Enabled (${current_width}x${current_height})"
    else
        scaling_label="Disabled (${current_width:-auto}x${current_height:-auto})"
    fi
    
    local pick
    pick="$(printf '%s\n' "Toggle Scaling" "Set Custom Resolution" "Clear Resolution" | \
        rofi -dmenu -i -p "Window Scaling: $scaling_label")"
    
    case "$pick" in
        "Toggle Scaling")
            if [ "$current_scaling" -eq 1 ]; then
                WINDOW_SCALING=0
            else
                WINDOW_SCALING=1
                # Set default resolution if not set
                if [ -z "$current_width" ] || [ -z "$current_height" ]; then
                    WINDOW_WIDTH=1280
                    WINDOW_HEIGHT=720
                fi
            fi
            ;;
        "Set Custom Resolution")
            local width height
            width="$(rofi -dmenu -p "Width (e.g., 1280, 1920, 480)" -filter "${current_width:-1280}")"
            [ -z "$width" ] && return
            height="$(rofi -dmenu -p "Height (e.g., 720, 1080, 270)" -filter "${current_height:-720}")"
            [ -z "$height" ] && return
            
            # Validate numeric input
            if [[ "$width" =~ ^[0-9]+$ ]] && [[ "$height" =~ ^[0-9]+$ ]]; then
                WINDOW_WIDTH="$width"
                WINDOW_HEIGHT="$height"
                WINDOW_SCALING=1
            else
                if command -v rofi >/dev/null 2>&1; then
                    rofi -e "Invalid resolution. Please enter numbers only."
                fi
            fi
            ;;
        "Clear Resolution")
            WINDOW_WIDTH=""
            WINDOW_HEIGHT=""
            WINDOW_SCALING=0
            ;;
    esac
}

# Pick mute on focus loss setting
pick_mute_on_focus_loss() {
    local current="${MUTE_ON_FOCUS_LOSS:-0}"
    local label
    if [ "$current" -eq 1 ]; then
        label="Enabled"
    else
        label="Disabled"
    fi
    
    local pick
    pick="$(printf '%s\n' "Toggle Mute on Focus Loss" | \
        rofi -dmenu -i -p "Mute on Focus Loss: $label")"
    
    if [ "$pick" = "Toggle Mute on Focus Loss" ]; then
        MUTE_ON_FOCUS_LOSS=$([ "$current" = "1" ] && echo 0 || echo 1)
    fi
}

# Show launch confirmation or settings menu
show_launch_or_settings() {
    local missing_count menu_lines choice mode_line

    while true; do
        missing_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM protons WHERE status='missing';")"

        case "$PREFIX_MODE" in
            auto)      mode_line="Prefix mode: Auto ($AUTO_NAME)" ;;
            directory) mode_line="Prefix mode: Directory ($DIR_NAME)" ;;
            manual)    mode_line="Prefix mode: Manual (${MANUAL_NAME:-not set})" ;;
            *)         mode_line="Prefix mode: Auto ($AUTO_NAME)" ;;
        esac

        # Build window settings display
        local window_line
        if [ -n "$WINDOW_WIDTH" ] && [ -n "$WINDOW_HEIGHT" ]; then
            if [ "$WINDOW_SCALING" -eq 1 ]; then
                window_line="Window: ${WINDOW_WIDTH}x${WINDOW_HEIGHT} (scaled)"
            else
                window_line="Window: ${WINDOW_WIDTH}x${WINDOW_HEIGHT} (fixed)"
            fi
        else
            window_line="Window: Default"
        fi

        menu_lines=(
            "\u25b6 Launch"
            "Proton: ${SEL_PROTON_NAME:-[none selected]}"
            "$mode_line"
            "$window_line"
            "Mute on Focus Loss: $([ "${MUTE_ON_FOCUS_LOSS:-0}" = "1" ] && echo On || echo Off)"
            "Cheat Engine autoboot: $([ "$CE_AUTOBOOT" = "1" ] && echo On || echo Off)"
            "MangoHud: $([ "$MANGOHUD" = "1" ] && echo On || echo Off)"
        )
        
        # Add extensions to menu if available
        if [ -n "$AVAILABLE_EXTENSIONS" ]; then
            for ext in $AVAILABLE_EXTENSIONS; do
                local ext_enabled="${EXTENSIONS_ENABLED[$ext]:-0}"
                menu_lines+=("$ext: $([ "$ext_enabled" = "1" ] && echo On || echo Off)")
            done
        fi
        
        if [ "${missing_count:-0}" -gt 0 ]; then
            menu_lines+=("Fix Proton list ($missing_count missing)")
        fi
        menu_lines+=("Cancel")

        if command -v rofi >/dev/null 2>&1; then
            choice="$(printf '%s\n' "${menu_lines[@]}" | rofi -dmenu -i -p "$GAME_NAME_DISPLAY")"
        else
            echo "Configuration for $GAME_NAME_DISPLAY:"
            for i in "${!menu_lines[@]}"; do
                echo "  $((i+1)). ${menu_lines[$i]}"
            done
            read -r -p "Select option (number or name): " choice
        fi

        case "$choice" in
            "\u25b6 Launch"|"1")
                if [ -z "$SEL_PROTON_NAME" ]; then
                    if command -v rofi >/dev/null 2>&1; then
                        rofi -e "Select a Proton version first."
                    else
                        echo "ERROR: Select a Proton version first."
                    fi
                    continue
                fi
                return 0
                ;;
            "Proton:"*)
                pick_proton
                ;;
            "Prefix mode:"*)
                pick_prefix_mode
                ;;
            "Window:"*)
                pick_window_scaling
                ;;
            "Mute on Focus Loss:"*)
                pick_mute_on_focus_loss
                ;;
            "Cheat Engine autoboot:"*)
                CE_AUTOBOOT=$([ "$CE_AUTOBOOT" = "1" ] && echo 0 || echo 1)
                ;;
            "MangoHud:"*)
                MANGOHUD=$([ "$MANGOHUD" = "1" ] && echo 0 || echo 1)
                ;;
            "Fix Proton list"*)
                manage_missing_protons
                ;;
            "Cancel"|\"")
                echo "Cancelled by user."
                exit 0
                ;;
            *)
                # Check if it's an extension toggle
                local found=0
                for ext in $AVAILABLE_EXTENSIONS; do
                    if [[ "$choice" == "$ext:"* ]]; then
                        EXTENSIONS_ENABLED[$ext]=$([ "${EXTENSIONS_ENABLED[$ext]:-0}" = "1" ] && echo 0 || echo 1)
                        found=1
                        break
                    fi
                done
                
                if [ "$found" -eq 0 ]; then
                    echo "Unknown option: $choice"
                fi
                ;;
        esac
    done
}

# Display error message
display_error() {
    local message="$1"
    
    if command -v rofi >/dev/null 2>&1; then
        rofi -e "$message"
    else
        echo "ERROR: $message" >&2
    fi
}

# Display info message
display_info() {
    local message="$1"
    
    if command -v rofi >/dev/null 2>&1; then
        rofi -e "$message"
    else
        echo "INFO: $message"
    fi
}
