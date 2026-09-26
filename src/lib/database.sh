#!/bin/bash
# Database Manager for Proton Launcher
# Implements versioned database schema

DB_VERSION=5

# Initialize database with versioning
init_database() {
    local db_path="${DB:-$HOME/.local/share/proton-launcher/games.db}"
    
    mkdir -p "$(dirname "$db_path")"
    
    # Check if database exists
    if [ ! -f "$db_path" ]; then
        create_database "$db_path"
        return 0
    fi
    
    # Check database version
    local current_version
    current_version=$(sqlite3 "$db_path" "SELECT value FROM meta WHERE key='version' LIMIT 1;" 2>/dev/null || echo "0")
    
    if [ "$current_version" -lt "$DB_VERSION" ]; then
        upgrade_database "$db_path" "$current_version"
    fi
}

# Create new database
create_database() {
    local db_path="$1"
    
    sqlite3 "$db_path" <<EOF
PRAGMA journal_mode=WAL;

-- Meta table for version tracking
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Insert version
INSERT INTO meta (key, value) VALUES ('version', '$DB_VERSION');

-- Games table
CREATE TABLE IF NOT EXISTS games (
    marker_id             TEXT PRIMARY KEY,
    name                  TEXT NOT NULL,
    prefix_mode           TEXT NOT NULL DEFAULT 'auto',
    manual_name           TEXT,
    proton_name           TEXT,
    cheat_engine_autoboot INTEGER NOT NULL DEFAULT 0,
    mangohud              INTEGER NOT NULL DEFAULT 1,
    is_32bit              INTEGER NOT NULL DEFAULT 0,
    last_path             TEXT,
    last_launched         TEXT,
    window_width          INTEGER,
    window_height         INTEGER,
    window_mode           TEXT NOT NULL DEFAULT 'default'
);

-- Running games table
CREATE TABLE IF NOT EXISTS running_games (
    marker_id   TEXT PRIMARY KEY,
    game_name   TEXT NOT NULL,
    game_path   TEXT,
    pid         INTEGER NOT NULL,
    proton      TEXT NOT NULL,
    proton_path TEXT NOT NULL,
    prefix      TEXT NOT NULL,
    started_at  TEXT NOT NULL
);

-- Proton installations table
CREATE TABLE IF NOT EXISTS protons (
    name      TEXT PRIMARY KEY,
    path      TEXT NOT NULL,
    status    TEXT NOT NULL DEFAULT 'active',
    last_seen TEXT
);

-- Game extensions table
CREATE TABLE IF NOT EXISTS game_extensions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    marker_id   TEXT NOT NULL,
    extension_name TEXT NOT NULL,
    enabled     INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (marker_id) REFERENCES games(marker_id)
);
EOF
    
    echo "Created new database at $db_path with version $DB_VERSION"
}

# Upgrade database schema
upgrade_database() {
    local db_path="$1"
    local from_version="$2"
    
    echo "Upgrading database from version $from_version to $DB_VERSION"
    
    # Backup existing database
    local backup_path="${db_path}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$db_path" "$backup_path"
    echo "Backup created at $backup_path"
    
    # Version 0 to 1: Add game_extensions table (old game-launcher databases)
    if [ "$from_version" -eq 0 ]; then
        sqlite3 "$db_path" <<'EOF'
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO meta (key, value) VALUES ('version', '1');

ALTER TABLE games ADD COLUMN is_32bit INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS game_extensions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    marker_id TEXT NOT NULL,
    extension_name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1
);
EOF
        from_version=1
    fi
    
    # Version 1 to 2: Add window settings
    if [ "$from_version" -eq 1 ]; then
        sqlite3 "$db_path" <<'EOF'
ALTER TABLE games ADD COLUMN window_width INTEGER;
ALTER TABLE games ADD COLUMN window_height INTEGER;
ALTER TABLE games ADD COLUMN window_scaling INTEGER NOT NULL DEFAULT 0;
EOF
        sqlite3 "$db_path" "UPDATE meta SET value='2' WHERE key='version';"
        from_version=2
    fi
    
    # Version 2 to 3: Add window_mode, remove window_scaling
    if [ "$from_version" -eq 2 ]; then
        sqlite3 "$db_path" <<'EOF'
ALTER TABLE games ADD COLUMN window_mode TEXT NOT NULL DEFAULT 'default';
EOF
        # Migrate old window_scaling to window_mode
        sqlite3 "$db_path" <<'EOF'
UPDATE games SET window_mode = 
    CASE 
        WHEN window_scaling = 1 AND window_width IS NOT NULL AND window_height IS NOT NULL 
        THEN 'fixed'
        ELSE 'default'
    END;
EOF
        sqlite3 "$db_path" "UPDATE meta SET value='3' WHERE key='version';"
        from_version=3
    fi
    
    # Version 3 to 4: Set default extension enabled to 0
    # NOTE: window_mode was already added in the 2->3 step above. Re-running
    # "ALTER TABLE games ADD COLUMN window_mode" here was a bug - it threw a
    # "duplicate column name" error on every fresh 0->5 migration chain.
    if [ "$from_version" -eq 3 ]; then
        sqlite3 "$db_path" <<'EOF'
UPDATE game_extensions SET enabled = 0 WHERE enabled = 1;
UPDATE games SET window_mode = 'default' WHERE window_mode IS NULL;
EOF
        sqlite3 "$db_path" "UPDATE meta SET value='4' WHERE key='version';"
        from_version=4
    fi
    
    # Version 4 to 5: Remove mute_on_focus_loss column if it exists (cleanup from old code)
    if [ "$from_version" -eq 4 ]; then
        sqlite3 "$db_path" "UPDATE meta SET value='5' WHERE key='version';"
        from_version=5
    fi
    
    echo "Database upgraded to version $DB_VERSION"
}

# SQL escape function
sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# Check if database needs migration
check_db_migration() {
    local db_path="${DB:-$HOME/.local/share/proton-launcher/games.db}"
    
    if [ ! -f "$db_path" ]; then
        return 0
    fi
    
    local current_version
    current_version=$(sqlite3 "$db_path" "SELECT value FROM meta WHERE key='version' LIMIT 1;" 2>/dev/null || echo "0")
    
    if [ "$current_version" -lt "$DB_VERSION" ]; then
        return 1  # Needs migration
    fi
    
    return 0  # Up to date
}
