#!/bin/bash
# UI Module for Proton Launcher
# Handles user interface interactions

# Pick window mode
pick_window_mode() {
    local current_mode="${WINDOW_MODE:-default}"
    local current_width="${WINDOW_WIDTH:-}"
    local current_height="${WINDOW_HEIGHT:-}"
    
    local mode_label
    case "$current_mode" in
        "default") mode_label="Default (Resizable KDE window)" ;;
        "fixed") mode_label="Fixed (${current_width}x${current_height})" ;;
        "fullscreen") mode_label="Force Fullscreen" ;;
        "maximized") mode_label="Force Maximized" ;;
        *) mode_label="Default (Resizable KDE window)" ;;
    esac
    
    local pick
    pick="$(printf '%s\n' "Default (Resizable)" "Fixed Resolution" "Force Fullscreen" "Force Maximized" | \
        rofi -dmenu -i -p "Window Mode: $mode_label")"
    
    case "$pick" in
        "Default (Resizable)")
            WINDOW_MODE="default"
            ;;
        "Fixed Resolution")
            WINDOW_MODE="fixed"
            # Open resolution picker
            local width height
            width="$(rofi -dmenu -p "Width (e.g., 480, 1280, 1920)" -filter "${current_width:-480}")"
            [ -z "$width" ] && return
            height="$(rofi -dmenu -p "Height (e.g., 270, 720, 1080)" -filter "${current_height:-270}")"
            [ -z "$height" ] && return
            
            # Validate numeric input
            if [[ "$width" =~ ^[0-9]+$ ]] && [[ "$height" =~ ^[0-9]+$ ]]; then
                WINDOW_WIDTH="$width"
                WINDOW_HEIGHT="$height"
            else
                if command -v rofi >/dev/null 2>&1; then
                    rofi -e "Invalid resolution. Please enter numbers only."
                fi
            fi
            ;;
        "Force Fullscreen")
            WINDOW_MODE="fullscreen"
            ;;
        "Force Maximized")
            WINDOW_MODE="maximized"
            ;;
    esac
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
        case "${WINDOW_MODE:-default}" in
            "default") window_line="Window: Default (Resizable)" ;;
            "fixed") 
                if [ -n "$WINDOW_WIDTH" ] && [ -n "$WINDOW_HEIGHT" ]; then
                    window_line="Window: Fixed ${WINDOW_WIDTH}x${WINDOW_HEIGHT}"
                else
                    window_line="Window: Fixed (set resolution)"
                fi
                ;;
            "fullscreen") window_line="Window: Force Fullscreen" ;;
            "maximized") window_line="Window: Force Maximized" ;;
            *) window_line="Window: Default (Resizable)" ;;
        esac

        menu_lines=(
            "\u25b6 Launch"
            "Proton: ${SEL_PROTON_NAME:-[none selected]}"
            "$mode_line"
            "$window_line"
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
                pick_window_mode
                ;;
            "Cheat Engine autoboot:"*)
                CE_AUTOBOOT=$([ "$CE_AUTOBOOT" = "1" ] && echo 0 || echo 1)
                ;;
            "MangoHud:"*)
                MANGOHUD=$([ "$MANGOHUD" = "1" ] && echo 0 || echo 1)
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
                    # Check for other menu options
                    case "$choice" in
                        "Fix Proton list"*)
                            manage_missing_protons
                            ;;
                        "Cancel")
                            echo "Cancelled by user."
                            exit 0
                            ;;
                        *)
                            echo "Unknown option: $choice"
                            ;;
                    esac
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
