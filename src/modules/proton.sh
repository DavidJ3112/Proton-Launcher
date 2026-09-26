#!/bin/bash
# Proton Module for Proton Launcher
# Handles Proton selection and management

# Pick Proton from available installations
pick_proton() {
    local list names pick path
    list="$(get_active_protons)"
    if [ -z "$list" ]; then
        if command -v rofi >/dev/null 2>&1; then
            rofi -e "No Proton installations found under:
$PROTON_BASE
$STEAM_PROTON"
        fi
        return
    fi

    names="$(printf '%s\n' "$list" | cut -d'|' -f1)"
    pick="$(printf '%s\n' "$names" | rofi -dmenu -i -p "Proton")"
    [ -z "$pick" ] && return

    path="$(printf '%s\n' "$list" | awk -F'|' -v n="$pick" '$1==n{print $2; exit}')"
    SEL_PROTON_NAME="$pick"
    SEL_PROTON_PATH="$path"
}

# Manage missing Proton installations
manage_missing_protons() {
    local missing names selected name esc_name
    missing="$(get_missing_protons)"
    [ -z "$missing" ] && return

    names="$(printf '%s\n' "$missing" | cut -d'|' -f1)"

    if command -v rofi >/dev/null 2>&1; then
        selected="$(printf '%s\n' "$names" | rofi -dmenu -multi-select -i \
            -p "Remove missing Proton(s) (Shift+Enter to pick several)")"
    else
        echo "Missing Proton installations:"
        echo "$names"
        read -r -p "Enter Proton name to remove (or leave empty to skip): " selected
    fi

    [ -z "$selected" ] && return

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        esc_name="$(sql_escape "$name")"
        sqlite3 "$DB" "DELETE FROM protons WHERE name = '$esc_name';"
        echo "Removed missing Proton entry: $name"
    done <<< "$selected"
}

# Pick prefix mode
pick_prefix_mode() {
    local pick entered
    pick="$(printf '%s\n' "Auto ($AUTO_NAME)" "Directory ($DIR_NAME)" "Manual" | \
        rofi -dmenu -i -p "Prefix mode")"

    case "$pick" in
        Auto*) PREFIX_MODE="auto" ;;
        Directory*) PREFIX_MODE="directory" ;;
        Manual*)
            entered="$(rofi -dmenu -p "Prefix name" -filter "${MANUAL_NAME:-$AUTO_NAME}")"
            [ -n "$entered" ] && MANUAL_NAME="$entered"
            PREFIX_MODE="manual"
            ;;
    esac
}
