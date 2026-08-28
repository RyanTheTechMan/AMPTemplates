#!/usr/bin/env bash
LAUNCHER_TEMPLATE_VERSION="19"
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

LAUNCHER_LOG=""

log() {
    local message="$*"
    printf '[AMP/AzerothCore] %s\n' "$message"
    if [[ -n "${LAUNCHER_LOG:-}" ]]; then
        printf '%s [AMP/AzerothCore] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$LAUNCHER_LOG" 2>/dev/null || true
    fi
}

fail() {
    local message="$*"
    printf '[AMP/AzerothCore] ERROR: %s\n' "$message" >&2
    if [[ -n "${LAUNCHER_LOG:-}" ]]; then
        printf '%s [AMP/AzerothCore] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$LAUNCHER_LOG" 2>/dev/null || true
    fi
    exit 1
}

sql_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

numeric_or_default() {
    local value="$1" fallback="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

is_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

boolean_number() {
    if is_true "$1"; then
        printf '1'
    else
        printf '0'
    fi
}

sanitize_info_value() {
    local value="${1:-unknown}"
    value="${value//$'\r'/_}"
    value="${value//$'\n'/_}"
    value="${value//[[:space:]]/_}"
    [[ -n "$value" ]] || value="unknown"
    printf '%s' "$value"
}

config_string() {
    local value="$1"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\#/ }"
    value="${value//\"/}"
    printf '"%s"' "$value"
}

config_has_key() {
    local config_file="$1" config_key="$2"
    AMP_CONFIG_KEY="$config_key" awk '
        BEGIN { target = ENVIRON["AMP_CONFIG_KEY"] }
        {
            candidate = $0
            sub(/^[[:space:]]*/, "", candidate)
            if (candidate ~ /^[#;]/)
                next
            separator = index(candidate, "=")
            if (separator <= 0)
                next
            key = substr(candidate, 1, separator - 1)
            sub(/[[:space:]]+$/, "", key)
            if (key == target)
                found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$config_file"
}

set_conf_value() {
    local config_file="$1" config_key="$2" config_value="$3" temporary_file
    [[ -f "$config_file" ]] || fail "Configuration file is missing: $config_file"
    temporary_file="$(mktemp "${config_file}.amp.XXXXXX")"
    AMP_CONFIG_KEY="$config_key" AMP_CONFIG_LINE="$config_key = $config_value" \
        awk '
            BEGIN {
                target = ENVIRON["AMP_CONFIG_KEY"]
                replacement = ENVIRON["AMP_CONFIG_LINE"]
                found = 0
            }
            {
                original = $0
                candidate = $0
                sub(/^[[:space:]]*/, "", candidate)
                if (candidate !~ /^[#;]/) {
                    separator = index(candidate, "=")
                    if (separator > 0) {
                        key = substr(candidate, 1, separator - 1)
                        sub(/[[:space:]]+$/, "", key)
                        if (key == target) {
                            if (!found)
                                print replacement
                            found = 1
                            next
                        }
                    }
                }
                print original
            }
            END {
                if (!found)
                    print replacement
            }
        ' "$config_file" > "$temporary_file"
    chmod --reference="$config_file" "$temporary_file" 2>/dev/null || true
    mv -f "$temporary_file" "$config_file"
}

set_conf_value_if_present() {
    local config_file="$1" config_key="$2" config_value="$3"
    if config_has_key "$config_file" "$config_key"; then
        set_conf_value "$config_file" "$config_key" "$config_value"
    else
        log "Selected core does not declare '$config_key'; leaving it unchanged"
    fi
}

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$BASE_DIR/source"
DIST_DIR="$BASE_DIR/dist"
BIN_DIR="$DIST_DIR/bin"
ETC_DIR="$DIST_DIR/etc"
MYSQL_DIR="$BASE_DIR/mysql"
MYSQL_COMPAT_DIR="$MYSQL_DIR/compat"
MYSQL_CLIENT_RUNTIME_DIR="$BASE_DIR/runtime/mysql-client"
MYSQL_DATA_DIR="$BASE_DIR/mysql-data"
MYSQL_RUN_DIR="$BASE_DIR/run/mysqld"
MYSQL_LOG_DIR="$BASE_DIR/logs/mysql"
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"
MYSQL_PID_FILE="$MYSQL_RUN_DIR/mysqld.pid"
STATE_DIR="$BASE_DIR/state"
OPENSSL_CONF_FILE="$STATE_DIR/openssl-azerothcore.cnf"
RUN_DIR="$BASE_DIR/run"
READY_MARKER="$RUN_DIR/worldserver.ready"
AUTH_PID_FILE="$RUN_DIR/authserver.pid"
WORLD_PID_FILE="$RUN_DIR/worldserver.pid"
READY_PID_FILE="$RUN_DIR/readiness-monitor.pid"
METRICS_PID_FILE="$RUN_DIR/metrics-monitor.pid"
MYSQL_SERVICE_PID_FILE="$RUN_DIR/mysql-service.pid"
WATCHDOG_PID_FILE="$RUN_DIR/shutdown-watchdog.pid"
LIFECYCLE_FILE="$RUN_DIR/lifecycle.id"
CLEANUP_LOCK_FILE="$RUN_DIR/cleanup.lock"
CLEANUP_COMPLETE_MARKER="$RUN_DIR/cleanup.complete"
WATCHDOG_SCRIPT="$BASE_DIR/azerothcore-watchdog.sh"
COMPANION_LIBRARY="$BASE_DIR/azerothcore-companions.sh"
READY_STABILITY_SECONDS=10
MYSQL_BUFFER_POOL_MB="$(numeric_or_default "${AMP_ACORE_MYSQL_BUFFER_POOL_MB:-1024}" 1024)"
METRICS_INTERVAL_SECONDS="$(numeric_or_default "${AMP_ACORE_METRICS_INTERVAL_SECONDS:-60}" 60)"
if (( METRICS_INTERVAL_SECONDS < 10 )); then
    METRICS_INTERVAL_SECONDS=10
fi
AUTH_PORT="$(numeric_or_default "${AMP_ACORE_AUTH_PORT:-3724}" 3724)"
WORLD_PORT="$(numeric_or_default "${AMP_ACORE_WORLD_PORT:-8085}" 8085)"
REALM_NAME="${AMP_ACORE_REALM_NAME:-AzerothCore - AMP}"
REALM_ADDRESS_MODE="${AMP_ACORE_REALM_ADDRESS_MODE:-auto}"
AUTO_REALM_ADDRESS="${AMP_ACORE_AUTO_REALM_ADDRESS:-127.0.0.1}"
MANUAL_REALM_ADDRESS="${AMP_ACORE_MANUAL_REALM_ADDRESS:-}"
REALM_ADDRESS="$AUTO_REALM_ADDRESS"
if [[ "$REALM_ADDRESS_MODE" == "manual" && -n "$MANUAL_REALM_ADDRESS" ]]; then
    REALM_ADDRESS="$MANUAL_REALM_ADDRESS"
fi
REALM_LOCAL_ADDRESS="${AMP_ACORE_REALM_LOCAL_ADDRESS:-127.0.0.1}"
REALM_LOCAL_SUBNET_MASK="${AMP_ACORE_REALM_LOCAL_SUBNET_MASK:-255.255.255.0}"
MYSQL_ADMIN_USER="$(id -un)"
DATABASE_USER="$MYSQL_ADMIN_USER"

mkdir -p "$MYSQL_RUN_DIR" "$MYSQL_LOG_DIR" "$BASE_DIR/logs" "$BASE_DIR/temp" "$RUN_DIR" "$STATE_DIR"
chmod 700 "$MYSQL_RUN_DIR" 2>/dev/null || true
LAUNCHER_LOG="$BASE_DIR/logs/amp-launcher.log"
touch "$LAUNCHER_LOG" 2>/dev/null || true
LIFECYCLE_ID="$(date -u +%s)-$$-${RANDOM:-0}-${RANDOM:-0}"
printf '%s\n' "$LIFECYCLE_ID" > "$LIFECYCLE_FILE"
rm -f "$CLEANUP_COMPLETE_MARKER" "$AUTH_PID_FILE" "$WORLD_PID_FILE" "$READY_PID_FILE" "$METRICS_PID_FILE" 2>/dev/null || true
log "Launcher v$LAUNCHER_TEMPLATE_VERSION starting as user $MYSQL_ADMIN_USER (PID $$, lifecycle $LIFECYCLE_ID)"

[[ -x "$BIN_DIR/authserver" ]] || fail "authserver is not installed; run Update first"
[[ -x "$BIN_DIR/worldserver" ]] || fail "worldserver is not installed; run Update first"
[[ -x "$MYSQL_DIR/bin/mysqld" ]] || fail "MySQL is not installed; run Update first"
[[ -x "$WATCHDOG_SCRIPT" ]] || fail "AzerothCore shutdown watchdog is missing or not executable; run Update first"
grep -Fq 'WATCHDOG_TEMPLATE_VERSION="19"' "$WATCHDOG_SCRIPT" \
    || fail "AzerothCore shutdown watchdog version does not match launcher v$LAUNCHER_TEMPLATE_VERSION; run Update first"
[[ -r "$COMPANION_LIBRARY" ]] || fail "Managed companion service library is missing; run Update first"
grep -Fq 'COMPANION_LIBRARY_VERSION="19"' "$COMPANION_LIBRARY" \
    || fail "Managed companion service library does not match launcher v$LAUNCHER_TEMPLATE_VERSION; run Update first"
# shellcheck source=azerothcore-companions.sh
source "$COMPANION_LIBRARY"
[[ "$COMPANION_LIBRARY_VERSION" == "$LAUNCHER_TEMPLATE_VERSION" ]] \
    || fail "Template/runtime version mismatch between launcher and companion library"
companion_runtime_initialize
[[ -e "$MYSQL_COMPAT_DIR/libaio.so.1" ]] || fail "MySQL libaio compatibility is missing; run Update first"
[[ -f "$ETC_DIR/authserver.conf" ]] || fail "authserver.conf is missing; run Update first"
[[ -f "$ETC_DIR/worldserver.conf" ]] || fail "worldserver.conf is missing; run Update first"
[[ -d "$BIN_DIR/dbc" && -d "$BIN_DIR/maps" && -d "$BIN_DIR/vmaps" && -d "$BIN_DIR/mmaps" ]] \
    || fail "Required client data is missing from dist/bin; enable client-data installation or provide extracted data"

# Keep Oracle MySQL's private libraries isolated from AzerothCore.  The MySQL
# tarball also ships its own OpenSSL tooling/libraries; allowing those to leak
# into worldserver caused provider discovery to target /usr/local/mysql.
MYSQL_LD_LIBRARY_PATH="$MYSQL_COMPAT_DIR:$MYSQL_DIR/lib:$MYSQL_DIR/lib/private"
ACORE_LD_LIBRARY_PATH="$MYSQL_COMPAT_DIR:$MYSQL_CLIENT_RUNTIME_DIR"
SYSTEM_OPENSSL="/usr/bin/openssl"

mysql_cli() {
    env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" "$MYSQL_DIR/bin/mysql" "$@"
}
mysqladmin_cli() {
    env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" "$MYSQL_DIR/bin/mysqladmin" "$@"
}

prepare_mysql_client_runtime() {
    local source_library target_name count=0
    mkdir -p "$MYSQL_CLIENT_RUNTIME_DIR"
    rm -f "$MYSQL_CLIENT_RUNTIME_DIR"/libmysqlclient.so* 2>/dev/null || true
    for source_library in "$MYSQL_DIR"/lib/libmysqlclient.so*; do
        [[ -e "$source_library" ]] || continue
        target_name="$(basename "$source_library")"
        ln -sfn "$(readlink -f "$source_library")" "$MYSQL_CLIENT_RUNTIME_DIR/$target_name"
        count=$((count + 1))
    done
    (( count > 0 )) || fail "Bundled MySQL client libraries are missing; run Update"
}
prepare_mysql_client_runtime
# Keep the documented private-socket path in AzerothCore's DB strings. Current
# AzerothCore mutates the "." socket marker to "localhost" after the first pool
# connection; MYSQL_UNIX_PORT makes the resulting C-client fallback use this
# same private socket instead of /tmp/mysql.sock.
export MYSQL_UNIX_PORT="$MYSQL_SOCKET"
export AC_LOGIN_DATABASE_INFO=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_auth"
export AC_WORLD_DATABASE_INFO=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_world"
export AC_CHARACTER_DATABASE_INFO=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_characters"
export AC_PLAYERBOTS_DATABASE_INFO=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_playerbots"
export AC_DATA_DIR="$BIN_DIR"
export AC_LOGS_DIR="$BASE_DIR/logs"
export AC_TEMP_DIR="$BASE_DIR/temp"
export AC_SOURCE_DIRECTORY="$BASE_DIR/source"
export AC_MYSQL_EXECUTABLE="$MYSQL_DIR/bin/mysql"
export AC_REALM_SERVER_PORT="$AUTH_PORT"
export AC_WORLD_SERVER_PORT="$WORLD_PORT"
export AC_BIND_IP="${AC_BIND_IP:-0.0.0.0}"
export AC_FORCE_CREATE_DB="${AC_FORCE_CREATE_DB:-1}"
export AC_UPDATES_ENABLE_DATABASES="${AC_UPDATES_ENABLE_DATABASES:-7}"
export AC_DISABLE_INTERACTIVE="${AC_DISABLE_INTERACTIVE:-1}"
# AMP checkbox substitutions may arrive as true/false strings. These two AzerothCore
# settings are read as integers, so normalize them before AzerothCore's environment
# override layer sees them.
export AC_SERVER_LOGIN_INFO="$(boolean_number "${AC_SERVER_LOGIN_INFO:-0}")"
export AC_AI_PLAYERBOT_ADD_CLASS_COMMAND="$(boolean_number "${AC_AI_PLAYERBOT_ADD_CLASS_COMMAND:-1}")"

verify_runtime_mysql_linkage() {
    local server_binary linked_mysql unresolved_runtime mysql_unresolved linked_crypto linked_ssl
    mysql_unresolved="$(env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" ldd "$MYSQL_DIR/bin/mysqld" 2>/dev/null | grep 'not found' || true)"
    [[ -z "$mysql_unresolved" ]] \
        || fail "mysqld has unresolved runtime libraries: $mysql_unresolved"
    for server_binary in "$BIN_DIR/authserver" "$BIN_DIR/worldserver"; do
        unresolved_runtime="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | grep 'not found' || true)"
        [[ -z "$unresolved_runtime" ]] \
            || fail "$(basename "$server_binary") has unresolved runtime libraries: $unresolved_runtime"
        linked_mysql="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | awk '/libmysqlclient\.so/{print $3; exit}')"
        [[ -n "$linked_mysql" && "$linked_mysql" == "$MYSQL_CLIENT_RUNTIME_DIR/"* ]] \
            || fail "$(basename "$server_binary") is not using the isolated bundled MySQL client library (resolved '${linked_mysql:-none}'). Run Update to rebuild the server."

        # AzerothCore was compiled against Debian OpenSSL.  Refuse to start if
        # Oracle MySQL's private OpenSSL libraries are shadowing the system copy,
        # because Debian's legacy provider must match the libcrypto in the process.
        linked_crypto="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | awk '/libcrypto\.so/{print $3; exit}')"
        linked_ssl="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | awk '/libssl\.so/{print $3; exit}')"
        [[ -n "$linked_crypto" && "$linked_crypto" != "$MYSQL_DIR/"* ]] \
            || fail "$(basename "$server_binary") is resolving libcrypto from the bundled MySQL tree ('${linked_crypto:-none}'); refusing mixed OpenSSL runtimes"
        [[ -z "$linked_ssl" || "$linked_ssl" != "$MYSQL_DIR/"* ]] \
            || fail "$(basename "$server_binary") is resolving libssl from the bundled MySQL tree ('$linked_ssl'); refusing mixed OpenSSL runtimes"
    done
}
verify_runtime_mysql_linkage

prepare_openssl_runtime() {
    local provider_output cipher_output legacy_module module_dir
    [[ -x "$SYSTEM_OPENSSL" ]] || fail "Debian system OpenSSL is missing at $SYSTEM_OPENSSL"
    command -v dpkg-query >/dev/null 2>&1 || fail "dpkg-query is missing from the Debian AMP container"

    # Do not use `openssl version -m` through PATH here. Oracle's portable MySQL
    # includes its own OpenSSL executable whose compiled MODULESDIR points at
    # /usr/local/mysql/lib64/ossl-modules. AzerothCore uses Debian's libcrypto,
    # so locate the matching Debian provider module from its owning package.
    legacy_module="$(dpkg-query -L openssl-provider-legacy 2>/dev/null | awk '/\/legacy\.so$/ {print; exit}')"
    if [[ -z "$legacy_module" ]]; then
        legacy_module="$(find /usr/lib /lib -type f -path '*/ossl-modules/legacy.so' -print -quit 2>/dev/null || true)"
    fi
    [[ -n "$legacy_module" && -r "$legacy_module" ]] \
        || fail "Debian OpenSSL legacy provider is not installed. The container requires the openssl-provider-legacy package."
    module_dir="$(dirname "$legacy_module")"

    export OPENSSL_MODULES="$module_dir"
    log "Debian OpenSSL provider modules: $OPENSSL_MODULES (legacy.so present)"

    cat > "$OPENSSL_CONF_FILE" <<'EOF'
# AzerothCore 3.3.5a still uses RC4 for the WoW protocol. Under OpenSSL 3,
# RC4 is supplied by the legacy provider, while the rest of AzerothCore still
# needs the normal default provider. Keep this configuration private to this
# AMP instance instead of modifying Debian's global OpenSSL configuration.
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
legacy = legacy_sect

[default_sect]
activate = 1

[legacy_sect]
activate = 1
EOF
    chmod 600 "$OPENSSL_CONF_FILE" 2>/dev/null || true

    provider_output="$(env -u LD_LIBRARY_PATH OPENSSL_CONF="$OPENSSL_CONF_FILE" OPENSSL_MODULES="$OPENSSL_MODULES" "$SYSTEM_OPENSSL" list -providers 2>&1)" \
        || fail "Debian OpenSSL could not load the AzerothCore provider configuration"
    grep -Eq '^[[:space:]]+default[[:space:]]*$' <<< "$provider_output" \
        || fail "Debian OpenSSL default provider did not activate"
    grep -Eq '^[[:space:]]+legacy[[:space:]]*$' <<< "$provider_output" \
        || fail "Debian OpenSSL legacy provider did not activate; RC4 required by WoW 3.3.5a is unavailable"

    cipher_output="$(env -u LD_LIBRARY_PATH OPENSSL_CONF="$OPENSSL_CONF_FILE" OPENSSL_MODULES="$OPENSSL_MODULES" "$SYSTEM_OPENSSL" list -cipher-algorithms 2>&1)" \
        || fail "Debian OpenSSL could not enumerate ciphers with the AzerothCore provider configuration"
    grep -Eq '(^|[[:space:]])RC4([[:space:]-]|$)' <<< "$cipher_output" \
        || fail "Debian OpenSSL legacy provider loaded but RC4 was not available"

    if ! printf 'amp-azerothcore-rc4-preflight' \
        | env -u LD_LIBRARY_PATH OPENSSL_CONF="$OPENSSL_CONF_FILE" OPENSSL_MODULES="$OPENSSL_MODULES" \
            "$SYSTEM_OPENSSL" enc -rc4 -K 00112233445566778899aabbccddeeff -nosalt >/dev/null 2>&1; then
        fail "Debian OpenSSL RC4 preflight failed; AzerothCore would crash during ARC4 initialization"
    fi

    export OPENSSL_CONF="$OPENSSL_CONF_FILE"
    log "OpenSSL runtime verified: Debian default + legacy providers active, RC4 available"
}

configure_server_files() {
    local database_auth database_world database_characters database_playerbots playerbots_config
    local start_money_gold start_money_copper player_save_interval_seconds player_save_interval_milliseconds
    local characters_per_realm heroic_characters_per_realm cross_faction_value chat_feed_value
    local playerbots_min_random_bots playerbots_max_random_bots playerbots_min_level playerbots_max_level
    local playerbots_active_floor_ms playerbots_active_ceiling_ms playerbots_values_validated
    database_auth=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_auth"
    database_world=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_world"
    database_characters=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_characters"
    database_playerbots=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_playerbots"
    start_money_gold="$(numeric_or_default "${AMP_ACORE_START_PLAYER_MONEY_GOLD:-0}" 0)"
    start_money_copper=$((start_money_gold * 10000))
    # AMP exposes this setting in seconds, while AzerothCore's PlayerSaveInterval
    # configuration value is measured in milliseconds. Current AzerothCore gives
    # AC_* environment variables precedence over worldserver.conf, so consume the
    # legacy variable only as an input and remove it before starting the servers.
    player_save_interval_seconds="$(numeric_or_default "${AMP_ACORE_PLAYER_SAVE_INTERVAL_SECONDS:-${AC_PLAYER_SAVE_INTERVAL:-900}}" 900)"
    player_save_interval_milliseconds=$((player_save_interval_seconds * 1000))
    unset AC_PLAYER_SAVE_INTERVAL
    characters_per_realm="$(numeric_or_default "${AMP_ACORE_CHARACTERS_PER_REALM:-10}" 10)"
    heroic_characters_per_realm="$(numeric_or_default "${AMP_ACORE_HEROIC_CHARACTERS_PER_REALM:-1}" 1)"
    (( heroic_characters_per_realm <= characters_per_realm )) \
        || fail "Heroic Characters Per Realm cannot exceed Characters Per Realm"
    playerbots_min_random_bots="$(numeric_or_default "${AC_AI_PLAYERBOT_MIN_RANDOM_BOTS:-100}" 100)"
    playerbots_max_random_bots="$(numeric_or_default "${AC_AI_PLAYERBOT_MAX_RANDOM_BOTS:-100}" 100)"
    AC_AI_PLAYERBOT_MIN_RANDOM_BOTS="$playerbots_min_random_bots"
    AC_AI_PLAYERBOT_MAX_RANDOM_BOTS="$playerbots_max_random_bots"
    playerbots_min_level="$(numeric_or_default "${AMP_ACORE_PLAYERBOTS_RANDOM_BOT_MIN_LEVEL:-1}" 1)"
    playerbots_max_level="$(numeric_or_default "${AMP_ACORE_PLAYERBOTS_RANDOM_BOT_MAX_LEVEL:-80}" 80)"
    playerbots_active_floor_ms="$(numeric_or_default "${AMP_ACORE_PLAYERBOTS_SMART_SCALE_FLOOR_MS:-50}" 50)"
    playerbots_active_ceiling_ms="$(numeric_or_default "${AMP_ACORE_PLAYERBOTS_SMART_SCALE_CEILING_MS:-200}" 200)"
    playerbots_values_validated=0
    cross_faction_value="$(boolean_number "${AMP_ACORE_ALLOW_CROSS_FACTION_INTERACTION:-0}")"
    chat_feed_value="$(boolean_number "${AMP_ACORE_ENABLE_CHAT_FEED:-0}")"

    log "Configuring AzerothCore databases through Unix socket $MYSQL_SOCKET as OS/MySQL user '$DATABASE_USER' (auth_socket, no password)"

    # Current AzerothCore reads AC_* environment variables. Writing the live config too
    # keeps historical source choices and module branches compatible. Less-common options
    # are only changed when the selected core declares them.
    set_conf_value "$ETC_DIR/authserver.conf" "LoginDatabaseInfo" "$(config_string "$database_auth")"
    set_conf_value "$ETC_DIR/authserver.conf" "RealmServerPort" "$AUTH_PORT"
    set_conf_value "$ETC_DIR/authserver.conf" "BindIP" "$(config_string "$AC_BIND_IP")"
    set_conf_value "$ETC_DIR/authserver.conf" "LogsDir" "$(config_string "$BASE_DIR/logs")"
    set_conf_value "$ETC_DIR/authserver.conf" "SourceDirectory" "$(config_string "$BASE_DIR/source")"
    set_conf_value "$ETC_DIR/authserver.conf" "MySQLExecutable" "$(config_string "$MYSQL_DIR/bin/mysql")"
    set_conf_value "$ETC_DIR/authserver.conf" "Updates.AutoSetup" "1"
    set_conf_value "$ETC_DIR/authserver.conf" "Updates.EnableDatabases" "1"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "ProcessPriority" "0"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "StrictVersionCheck" "$(boolean_number "${AMP_ACORE_STRICT_VERSION_CHECK:-0}")"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "WrongPass.MaxCount" "${AMP_ACORE_WRONG_PASS_MAX_COUNT:-0}"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "WrongPass.BanTime" "${AMP_ACORE_WRONG_PASS_BAN_TIME:-600}"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "WrongPass.BanType" "${AMP_ACORE_WRONG_PASS_BAN_TYPE:-0}"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "WrongPass.Logging" "$(boolean_number "${AMP_ACORE_WRONG_PASS_LOGGING:-0}")"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "EnableProxyProtocol" "$(boolean_number "${AMP_ACORE_ENABLE_PROXY_PROTOCOL:-0}")"
    set_conf_value_if_present "$ETC_DIR/authserver.conf" "AllowLoggingIPAddressesInDatabase" "$(boolean_number "${AMP_ACORE_ALLOW_LOGGING_IP_ADDRESSES:-1}")"

    set_conf_value "$ETC_DIR/worldserver.conf" "RealmID" "1"
    set_conf_value "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo" "$(config_string "$database_auth")"
    set_conf_value "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo" "$(config_string "$database_world")"
    set_conf_value "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "$(config_string "$database_characters")"
    set_conf_value "$ETC_DIR/worldserver.conf" "DataDir" "$(config_string "$BIN_DIR")"
    set_conf_value "$ETC_DIR/worldserver.conf" "LogsDir" "$(config_string "$BASE_DIR/logs")"
    set_conf_value "$ETC_DIR/worldserver.conf" "TempDir" "$(config_string "$BASE_DIR/temp")"
    set_conf_value "$ETC_DIR/worldserver.conf" "SourceDirectory" "$(config_string "$BASE_DIR/source")"
    set_conf_value "$ETC_DIR/worldserver.conf" "MySQLExecutable" "$(config_string "$MYSQL_DIR/bin/mysql")"
    set_conf_value "$ETC_DIR/worldserver.conf" "WorldServerPort" "$WORLD_PORT"
    set_conf_value "$ETC_DIR/worldserver.conf" "BindIP" "$(config_string "$AC_BIND_IP")"
    set_conf_value "$ETC_DIR/worldserver.conf" "PlayerLimit" "${AC_PLAYER_LIMIT:-100}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Motd" "$(config_string "${AC_MOTD:-Welcome to an AzerothCore server powered by AMP!}")"
    set_conf_value "$ETC_DIR/worldserver.conf" "GameType" "${AC_GAME_TYPE:-0}"
    set_conf_value "$ETC_DIR/worldserver.conf" "StartPlayerLevel" "${AC_START_PLAYER_LEVEL:-1}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "CharactersPerRealm" "$characters_per_realm"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "HeroicCharactersPerRealm" "$heroic_characters_per_realm"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "CharacterCreating.MinLevelForHeroicCharacter" "${AMP_ACORE_HEROIC_CHARACTER_UNLOCK_LEVEL:-55}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "StartHeroicPlayerLevel" "${AMP_ACORE_START_HEROIC_PLAYER_LEVEL:-55}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "MinDualSpecLevel" "${AMP_ACORE_MIN_DUAL_SPEC_LEVEL:-40}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "MaxPrimaryTradeSkill" "${AMP_ACORE_MAX_PRIMARY_TRADE_SKILL:-2}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "PreventAFKLogout" "${AMP_ACORE_PREVENT_AFK_LOGOUT:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AllFlightPaths" "$(boolean_number "${AMP_ACORE_ALL_FLIGHT_PATHS:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "InstantFlightPaths" "${AMP_ACORE_INSTANT_FLIGHT_PATHS:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AlwaysMaxSkillForLevel" "$(boolean_number "${AMP_ACORE_ALWAYS_MAX_SKILL_FOR_LEVEL:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AlwaysMaxWeaponSkill" "$(boolean_number "${AMP_ACORE_ALWAYS_MAX_WEAPON_SKILL:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "StartPlayerMoney" "$start_money_copper"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "SkipCinematics" "${AC_SKIP_CINEMATICS:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "PlayerStart.String" "$(config_string "${AC_PLAYER_START_STRING:-}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Server.LoginInfo" "$(boolean_number "${AC_SERVER_LOGIN_INFO:-0}")"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.XP.Kill" "${AC_RATE_XP_KILL:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.XP.Quest" "${AC_RATE_XP_QUEST:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.XP.Explore" "${AC_RATE_XP_EXPLORE:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Money" "${AC_RATE_DROP_MONEY:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Poor" "${AC_RATE_DROP_ITEM_POOR:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Normal" "${AC_RATE_DROP_ITEM_NORMAL:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Uncommon" "${AC_RATE_DROP_ITEM_UNCOMMON:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Rare" "${AC_RATE_DROP_ITEM_RARE:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Epic" "${AC_RATE_DROP_ITEM_EPIC:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Legendary" "${AC_RATE_DROP_ITEM_LEGENDARY:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Artifact" "${AC_RATE_DROP_ITEM_ARTIFACT:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Drop.Item.Referenced" "${AC_RATE_DROP_ITEM_REFERENCED:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Rate.Reputation.Gain" "${AC_RATE_REPUTATION_GAIN:-1}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.Honor" "${AC_RATE_HONOR:-1}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.ArenaPoints" "${AC_RATE_ARENA_POINTS:-1}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.RewardQuestMoney" "${AC_RATE_REWARD_QUEST_MONEY:-1}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.RewardBonusMoney" "${AC_RATE_REWARD_BONUS_MONEY:-1}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.RepairCost" "${AMP_ACORE_RATE_REPAIR_COST:-1}"

    local creature_rank
    for creature_rank in Normal Elite.RAREELITE Elite.Elite Elite.WORLDBOSS Elite.RARE; do
        set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.Creature.$creature_rank.HP" "${AMP_ACORE_RATE_CREATURE_HEALTH:-1}"
        set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.Creature.$creature_rank.Damage" "${AMP_ACORE_RATE_CREATURE_DAMAGE:-1}"
        set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Rate.Creature.$creature_rank.SpellDamage" "${AMP_ACORE_RATE_CREATURE_SPELL_DAMAGE:-1}"
    done

    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "NoResetTalentsCost" "$(boolean_number "${AC_NO_RESET_TALENTS_COST:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Instance.IgnoreLevel" "$(boolean_number "${AC_INSTANCE_IGNORE_LEVEL:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Instance.IgnoreRaid" "$(boolean_number "${AC_INSTANCE_IGNORE_RAID:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Instance.ResetTimeHour" "${AC_INSTANCE_RESET_TIME_HOUR:-4}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AllowTwoSide.Accounts" "$(boolean_number "${AC_ALLOW_TWO_SIDE_ACCOUNTS:-0}")"
    local interaction_key
    for interaction_key in Chat Channel Group Guild Arena Auction; do
        set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AllowTwoSide.Interaction.$interaction_key" "$cross_faction_value"
    done
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "PlayerSaveInterval" "$player_save_interval_milliseconds"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "PlayerSave.AdditionalSaves" "${AC_PLAYER_SAVE_ADDITIONAL_SAVES:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Warden.Enabled" "$(boolean_number "${AC_WARDEN_ENABLED:-1}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Network.EnableProxyProtocol" "$(boolean_number "${AMP_ACORE_ENABLE_PROXY_PROTOCOL:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AllowLoggingIPAddressesInDatabase" "$(boolean_number "${AMP_ACORE_ALLOW_LOGGING_IP_ADDRESSES:-1}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Allow.IP.Based.Action.Logging" "$(boolean_number "${AC_ALLOW_IP_BASED_ACTION_LOGGING:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "MaxCoreStuckTime" "${AC_MAX_CORE_STUCK_TIME:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "ThreadPool" "${AC_THREAD_POOL:-2}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "ProcessPriority" "0"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Compression" "${AC_COMPRESSION:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "MapUpdate.Threads" "${AC_MAP_UPDATE_THREADS:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Network.Threads" "${AC_NETWORK_THREADS:-1}"
    set_conf_value "$ETC_DIR/worldserver.conf" "Updates.AutoSetup" "1"
    set_conf_value "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "7"

    # Dedicated, prefix-free console appenders give AMP stable parseable lines for
    # human joins/leaves and optional chat without changing the rest of the console.
    set_conf_value "$ETC_DIR/worldserver.conf" "Appender.AMP" "1,4,0"
    set_conf_value "$ETC_DIR/worldserver.conf" "Logger.entities.player" "4,AMP Server"
    set_conf_value "$ETC_DIR/worldserver.conf" "Appender.AMPChat" "1,4,0"
    set_conf_value "$ETC_DIR/worldserver.conf" "ChatLog.Enable" "$chat_feed_value"
    if (( chat_feed_value == 1 )); then
        set_conf_value "$ETC_DIR/worldserver.conf" "Logger.chat" "4,AMPChat"
    else
        set_conf_value "$ETC_DIR/worldserver.conf" "Logger.chat" "0,AMPChat"
    fi
    set_conf_value "$ETC_DIR/worldserver.conf" "Logger.chat.addon" "0,AMPChat"

    for playerbots_config in \
        "$ETC_DIR/modules/playerbots.conf" \
        "$ETC_DIR/playerbots.conf" \
        "$ETC_DIR/modules/mod-playerbots.conf" \
        "$ETC_DIR/mod-playerbots.conf"; do
        [[ -f "$playerbots_config" ]] || continue
        if (( playerbots_values_validated == 0 )); then
            (( playerbots_min_random_bots <= playerbots_max_random_bots )) \
                || fail "Minimum Random Bots cannot exceed Maximum Random Bots"
            (( playerbots_min_level <= playerbots_max_level )) \
                || fail "Random Bot Minimum Level cannot exceed Random Bot Maximum Level"
            (( playerbots_active_floor_ms < playerbots_active_ceiling_ms )) \
                || fail "Playerbots SmartScale floor must be lower than its ceiling"
            playerbots_values_validated=1
        fi
        set_conf_value "$playerbots_config" "PlayerbotsDatabaseInfo" "$(config_string "$database_playerbots")"
        set_conf_value "$playerbots_config" "AiPlayerbot.Enabled" "${AC_AI_PLAYERBOT_ENABLED:-1}"
        set_conf_value "$playerbots_config" "AiPlayerbot.RandomBotAutologin" "${AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN:-1}"
        set_conf_value "$playerbots_config" "AiPlayerbot.MinRandomBots" "$playerbots_min_random_bots"
        set_conf_value "$playerbots_config" "AiPlayerbot.MaxRandomBots" "$playerbots_max_random_bots"
        set_conf_value "$playerbots_config" "AiPlayerbot.DisabledWithoutRealPlayer" "${AC_AI_PLAYERBOT_DISABLED_WITHOUT_REAL_PLAYER:-0}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.DisabledWithoutRealPlayerLoginDelay" "${AC_AI_PLAYERBOT_DISABLED_WITHOUT_REAL_PLAYER_LOGIN_DELAY:-30}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.DisabledWithoutRealPlayerLogoutDelay" "${AC_AI_PLAYERBOT_DISABLED_WITHOUT_REAL_PLAYER_LOGOUT_DELAY:-300}"
        set_conf_value "$playerbots_config" "AiPlayerbot.MaxAddedBots" "${AC_AI_PLAYERBOT_MAX_ADDED_BOTS:-40}"
        set_conf_value "$playerbots_config" "AiPlayerbot.AddClassAccountPoolSize" "${AC_AI_PLAYERBOT_ADD_CLASS_ACCOUNT_POOL_SIZE:-50}"
        set_conf_value "$playerbots_config" "AiPlayerbot.RandomBotAccountCount" "${AC_AI_PLAYERBOT_RANDOM_BOT_ACCOUNT_COUNT:-0}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.BotAutologin" "${AC_AI_PLAYERBOT_BOT_AUTOLOGIN:-0}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.AllowAccountBots" "${AC_AI_PLAYERBOT_ALLOW_ACCOUNT_BOTS:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.AllowGuildBots" "${AC_AI_PLAYERBOT_ALLOW_GUILD_BOTS:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.AllowTrustedAccountBots" "${AC_AI_PLAYERBOT_ALLOW_TRUSTED_ACCOUNT_BOTS:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotsPerInterval" "${AC_AI_PLAYERBOT_RANDOM_BOTS_PER_INTERVAL:-60}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotUpdateInterval" "${AC_AI_PLAYERBOT_RANDOM_BOT_UPDATE_INTERVAL:-20}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.GroupInvitationPermission" "${AC_AI_PLAYERBOT_GROUP_INVITATION_PERMISSION:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.AddClassCommand" "${AC_AI_PLAYERBOT_ADD_CLASS_COMMAND:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotGuildCount" "${AC_AI_PLAYERBOT_RANDOM_BOT_GUILD_COUNT:-20}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotGuildSizeMax" "${AC_AI_PLAYERBOT_RANDOM_BOT_GUILD_SIZE_MAX:-15}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotInvitePlayer" "${AC_AI_PLAYERBOT_RANDOM_BOT_INVITE_PLAYER:-0}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotTalk" "${AC_AI_PLAYERBOT_RANDOM_BOT_TALK:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotEmote" "${AC_AI_PLAYERBOT_RANDOM_BOT_EMOTE:-0}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.EnableBroadcasts" "${AC_AI_PLAYERBOT_ENABLE_BROADCASTS:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotRandomPassword" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_RANDOM_PASSWORDS:-1}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotMinLevel" "$playerbots_min_level"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotMaxLevel" "$playerbots_max_level"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotXPRate" "${AMP_ACORE_PLAYERBOTS_RANDOM_BOT_XP_RATE:-1}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.SyncLevelWithPlayers" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_SYNC_LEVEL_WITH_PLAYERS:-0}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.RandomBotJoinLfg" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_RANDOM_BOT_JOIN_LFG:-1}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.BotActiveAlone" "${AMP_ACORE_PLAYERBOTS_ACTIVE_ALONE_PERCENT:-10}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.BotActiveAloneDurationSeconds" "${AMP_ACORE_PLAYERBOTS_ACTIVE_ALONE_ROTATION_SECONDS:-30}"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.botActiveAloneSmartScale" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_SMART_SCALE:-1}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.botActiveAloneSmartScaleDiffLimitfloor" "$playerbots_active_floor_ms"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.botActiveAloneSmartScaleDiffLimitCeiling" "$playerbots_active_ceiling_ms"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.AutoAvoidAoe" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_AUTO_AVOID_AOE:-1}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.SyncQuestWithPlayer" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_SYNC_QUEST_WITH_PLAYER:-1}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.SyncQuestForPlayer" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_SYNC_QUEST_FOR_PLAYER:-0}")"
        set_conf_value_if_present "$playerbots_config" "AiPlayerbot.EnableICCBuffs" "$(boolean_number "${AMP_ACORE_PLAYERBOTS_ENABLE_ICC_BUFFS:-1}")"
        set_conf_value "$playerbots_config" "AiPlayerbot.CommandServerPort" "0"
    done
}
MYSQL_PID=""
AUTH_PID=""
WORLD_PID=""
READY_PID=""
METRICS_PID=""
CLEANED_UP="false"

mysql_server_args() {
    MYSQL_SERVER_ARGS=(
        --no-defaults
        "--basedir=$MYSQL_DIR"
        "--datadir=$MYSQL_DATA_DIR"
        "--socket=$MYSQL_SOCKET"
        "--pid-file=$MYSQL_PID_FILE"
        "--log-error=$MYSQL_LOG_DIR/mysql-error.log"
        --skip-networking
        --mysqlx=OFF
        --skip-log-bin
        --skip-name-resolve
        --plugin-load-add=auth_socket.so
        --character-set-server=utf8mb4
        --collation-server=utf8mb4_unicode_ci
        --transaction-isolation=READ-COMMITTED
        "--innodb-buffer-pool-size=${MYSQL_BUFFER_POOL_MB}M"
        --max-connections=250
        --upgrade=FORCE
    )
    if (( EUID == 0 )); then
        MYSQL_SERVER_ARGS+=(--user=root)
    fi
}

mysql_ready() {
    mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" ping >/dev/null 2>&1
}

verify_azerothcore_database_socket() {
    local auth_identity fallback_identity

    # Explicit socket path: matches AzerothCore's documented
    # ".;/path/to/socket;user;password;database" Linux format.
    auth_identity="$(mysql_cli --no-defaults --protocol=socket --socket="$MYSQL_SOCKET" \
        --user="$DATABASE_USER" --connect-timeout=5 --batch --skip-column-names \
        -e 'SELECT CURRENT_USER();' 2>/dev/null || true)"
    [[ "$auth_identity" == "$DATABASE_USER@localhost" ]] \
        || fail "Passwordless auth_socket login failed through $MYSQL_SOCKET as OS user '$DATABASE_USER'; run Update to repair MySQL accounts"

    # Current AzerothCore has an upstream bug that changes the stored socket host
    # from "." to "localhost" after the first pool connection. The next C API
    # connection then has no explicit unix_socket argument. MySQL documents
    # MYSQL_UNIX_PORT as the default Unix socket for localhost, so verify that
    # exact fallback before starting authserver.
    fallback_identity="$(MYSQL_UNIX_PORT="$MYSQL_SOCKET" mysql_cli --no-defaults \
        --protocol=socket --host=localhost --user="$DATABASE_USER" --connect-timeout=5 \
        --batch --skip-column-names -e 'SELECT CURRENT_USER();' 2>/dev/null || true)"
    [[ "$fallback_identity" == "$DATABASE_USER@localhost" ]] \
        || fail "AzerothCore's localhost socket fallback is not resolving through MYSQL_UNIX_PORT=$MYSQL_SOCKET"

    log "MySQL passwordless auth_socket verified for OS user '$DATABASE_USER'"
    log "AzerothCore socket fallback pinned to $MYSQL_SOCKET via MYSQL_UNIX_PORT"
}

start_mysql() {
    local timeout_count=180
    if mysql_ready; then
        log "Instance-local MySQL is already running"
        if [[ -r "$MYSQL_PID_FILE" ]]; then
            MYSQL_PID="$(tr -dc '0-9' < "$MYSQL_PID_FILE" 2>/dev/null || true)"
            write_pid_record "$MYSQL_SERVICE_PID_FILE" "$MYSQL_PID"
        fi
        return
    fi
    rm -f "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" "$MYSQL_PID_FILE"
    mysql_server_args
    log "Starting instance-local MySQL"
    env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" "$MYSQL_DIR/bin/mysqld" "${MYSQL_SERVER_ARGS[@]}" &
    MYSQL_PID=$!
    write_pid_record "$MYSQL_SERVICE_PID_FILE" "$MYSQL_PID"

    while (( timeout_count-- > 0 )); do
        if mysql_ready; then
            log "MySQL is ready"
            return
        fi
        if ! process_is_running "$MYSQL_PID"; then
            tail -n 100 "$MYSQL_LOG_DIR/mysql-error.log" >&2 || true
            fail "MySQL exited during startup"
        fi
        sleep 1
    done
    tail -n 100 "$MYSQL_LOG_DIR/mysql-error.log" >&2 || true
    fail "Timed out waiting for MySQL"
}

create_databases() {
    mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" <<'SQL'
CREATE DATABASE IF NOT EXISTS acore_auth CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_characters CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_world CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_playerbots CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
}

start_authserver() {
    log "Starting authserver"
    env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" OPENSSL_CONF="$OPENSSL_CONF" OPENSSL_MODULES="$OPENSSL_MODULES" \
        "$BIN_DIR/authserver" -c "$ETC_DIR/authserver.conf" </dev/null &
    AUTH_PID=$!
    write_pid_record "$AUTH_PID_FILE" "$AUTH_PID"
}

repair_auth_base_schema() {
    local base_dir="$BASE_DIR/source/data/sql/base/db_auth"
    local file table_name exists repaired=0 checked=0 missing=0
    local -a sql_files=()

    [[ -d "$base_dir" ]] || fail "Authentication base schema directory is missing: $base_dir"

    shopt -s nullglob
    sql_files=("$base_dir"/*.sql)
    shopt -u nullglob
    (( ${#sql_files[@]} > 0 )) || fail "No authentication base-schema SQL files were found in $base_dir"

    log "Checking authentication base schema for interrupted/partial first-run imports"
    for file in "${sql_files[@]}"; do
        table_name="$(basename "$file" .sql)"

        # AzerothCore's auth base directory uses one table per same-named SQL
        # file. Only repair files that declare that expected table; this avoids
        # replaying an unrelated base file against an existing database.
        if ! grep -Eq "CREATE TABLE( IF NOT EXISTS)? \`$table_name\`" "$file"; then
            continue
        fi

        checked=$((checked + 1))
        exists="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='acore_auth' AND table_name='$(sql_escape "$table_name")';")"
        if [[ "$exists" != "1" ]]; then
            log "Repairing missing authentication base table '$table_name' from $(basename "$file")"
            mysql_cli --no-defaults --protocol=socket --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" \
                acore_auth < "$file" \
                || fail "Failed to import missing authentication base table '$table_name' from $file"
            repaired=$((repaired + 1))
        fi
    done

    (( checked > 0 )) || fail "Could not identify any same-named authentication base tables in $base_dir"

    # Verify the full same-named base-table set after repairs. AzerothCore's
    # Populate() intentionally skips base import as soon as SHOW TABLES returns
    # any rows, so a previously interrupted import otherwise remains incomplete.
    for file in "${sql_files[@]}"; do
        table_name="$(basename "$file" .sql)"
        if ! grep -Eq "CREATE TABLE( IF NOT EXISTS)? \`$table_name\`" "$file"; then
            continue
        fi
        exists="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='acore_auth' AND table_name='$(sql_escape "$table_name")';")"
        if [[ "$exists" != "1" ]]; then
            log "Authentication base table is still missing after repair: $table_name"
            missing=$((missing + 1))
        fi
    done
    (( missing == 0 )) || fail "Authentication base schema is incomplete after repair ($missing table(s) still missing)"

    if (( repaired > 0 )); then
        log "Authentication base schema repaired successfully ($repaired missing table(s) restored; $checked checked)"
    else
        log "Authentication base schema verified complete ($checked table(s) checked)"
    fi
}

wait_for_authserver_ready() {
    local phase="${1:-authserver}" timeout_count=900 dead_checks=0
    log "Waiting for $phase to finish database setup and listen on 127.0.0.1:$AUTH_PORT"
    while (( timeout_count-- > 0 )); do
        if [[ -n "$AUTH_PID" ]] && process_is_running "$AUTH_PID" && port_is_open 127.0.0.1 "$AUTH_PORT"; then
            log "$phase is ready on authentication port $AUTH_PORT"
            return 0
        fi
        if [[ -n "$AUTH_PID" ]] && ! process_is_running "$AUTH_PID"; then
            dead_checks=$((dead_checks + 1))
            if (( dead_checks >= 3 )); then
                wait "$AUTH_PID" 2>/dev/null || true
                AUTH_PID=""
                tail -n 120 "$BASE_DIR/logs/Auth.log" >&2 2>/dev/null || true
                tail -n 120 "$BASE_DIR/logs/Errors.log" >&2 2>/dev/null || true
                fail "$phase exited before becoming ready"
            fi
        else
            dead_checks=0
        fi
        sleep 1
    done
    fail "Timed out waiting for $phase to listen on authentication port $AUTH_PORT"
}

update_realm_record() {
    local escaped_name escaped_address escaped_local_address escaped_subnet
    REALM_NAME="${REALM_NAME:0:32}"
    [[ -n "$REALM_ADDRESS" ]] || REALM_ADDRESS="127.0.0.1"
    [[ -n "$REALM_LOCAL_ADDRESS" ]] || REALM_LOCAL_ADDRESS="$REALM_ADDRESS"
    [[ -n "$REALM_LOCAL_SUBNET_MASK" ]] || REALM_LOCAL_SUBNET_MASK="255.255.255.0"

    escaped_name="$(sql_escape "$REALM_NAME")"
    escaped_address="$(sql_escape "$REALM_ADDRESS")"
    escaped_local_address="$(sql_escape "$REALM_LOCAL_ADDRESS")"
    escaped_subnet="$(sql_escape "$REALM_LOCAL_SUBNET_MASK")"

    mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" <<SQL
INSERT INTO acore_auth.realmlist
    (id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild)
VALUES
    (1, '$escaped_name', '$escaped_address', '$escaped_local_address', '$escaped_subnet', $WORLD_PORT, 0, 0, 1, 0, 0, 12340)
ON DUPLICATE KEY UPDATE
    name=VALUES(name),
    address=VALUES(address),
    localAddress=VALUES(localAddress),
    localSubnetMask=VALUES(localSubnetMask),
    port=VALUES(port),
    gamebuild=VALUES(gamebuild),
    flag=0;
SQL
    log "Realm '$REALM_NAME' advertises $REALM_ADDRESS:$WORLD_PORT"
}

port_is_open() {
    local host="$1" port="$2"
    (exec 9<>"/dev/tcp/$host/$port") >/dev/null 2>&1
}

mysql_scalar() {
    local query="$1"
    mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" \
        --batch --skip-column-names --connect-timeout=3 -e "$query" 2>/dev/null | head -n1
}

installed_report_value() {
    local field="$1"
    [[ -f "$BASE_DIR/AMP-INSTALLED-VERSION.txt" ]] || return 0
    sed -n "s/^${field}:[[:space:]]*//p" "$BASE_DIR/AMP-INSTALLED-VERSION.txt" | head -n1
}

emit_server_info() {
    local distribution core_ref core_commit modules client_data mysql_version modules_list report_modules

    distribution="$(cat "$STATE_DIR/distribution" 2>/dev/null || true)"
    [[ -n "$distribution" ]] || distribution="$(installed_report_value 'Distribution')"
    [[ -n "$distribution" ]] || distribution="unknown"

    core_ref="$(cat "$STATE_DIR/core-ref" 2>/dev/null || true)"
    [[ -n "$core_ref" ]] || core_ref="$(installed_report_value 'Core ref')"
    [[ -n "$core_ref" ]] || core_ref="unknown"

    core_commit="$(cat "$STATE_DIR/core-commit" 2>/dev/null || true)"
    [[ -n "$core_commit" ]] || core_commit="$(installed_report_value 'Core commit')"
    [[ -n "$core_commit" ]] || core_commit="unknown"
    core_commit="${core_commit:0:12}"

    modules_list="$(cat "$STATE_DIR/managed-modules" 2>/dev/null || true)"
    if [[ -n "$modules_list" ]]; then
        modules="$(printf '%s\n' "$modules_list" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    elif [[ -f "$BASE_DIR/AMP-INSTALLED-VERSION.txt" ]]; then
        report_modules="$(grep -c '^  - ' "$BASE_DIR/AMP-INSTALLED-VERSION.txt" 2>/dev/null || true)"
        modules="${report_modules:-0}"
    else
        modules=0
    fi

    client_data="$(cat "$STATE_DIR/client-data-version" 2>/dev/null || true)"
    [[ -n "$client_data" ]] || client_data="$(installed_report_value 'Client data')"
    [[ -n "$client_data" ]] || client_data="manual"

    mysql_version="$(cat "$STATE_DIR/mysql-version" 2>/dev/null || true)"
    [[ -n "$mysql_version" ]] || mysql_version="$(installed_report_value 'MySQL version')"
    if [[ -z "$mysql_version" && -x "$MYSQL_DIR/bin/mysqld" ]]; then
        mysql_version="$(env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" "$MYSQL_DIR/bin/mysqld" --version 2>/dev/null | sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' | head -n1)"
    fi
    [[ -n "$mysql_version" ]] || mysql_version="unknown"

    printf 'AMP_AZEROTHCORE_INFO Distribution=%s CoreRef=%s CoreCommit=%s Modules=%s ClientData=%s MySQL=%s\n' \
        "$(sanitize_info_value "$distribution")" \
        "$(sanitize_info_value "$core_ref")" \
        "$(sanitize_info_value "$core_commit")" \
        "$modules" \
        "$(sanitize_info_value "$client_data")" \
        "$(sanitize_info_value "$mysql_version")"
}

installed_distribution() {
    local distribution
    distribution="$(cat "$STATE_DIR/distribution" 2>/dev/null || true)"
    [[ -n "$distribution" ]] || distribution="$(installed_report_value 'Distribution')"
    printf '%s' "$distribution"
}

is_playerbots_distribution() {
    local distribution
    distribution="$(installed_distribution)"
    [[ "$distribution" == playerbots-* ]]
}

emit_metrics() {
    # AMP already tracks real players through Console.UserJoinRegex/UserLeaveRegex
    # as its native "Active Users" metric. Only publish one custom metric for
    # Playerbots builds: the number of socketless bot characters currently online.
    local human_sessions online_characters bots_online
    is_playerbots_distribution || return 0

    human_sessions="$(mysql_scalar 'SELECT COUNT(*) FROM acore_auth.account WHERE online <> 0;' || true)"
    online_characters="$(mysql_scalar 'SELECT COUNT(*) FROM acore_characters.characters WHERE online <> 0;' || true)"
    [[ "$human_sessions" =~ ^[0-9]+$ ]] || return 0
    [[ "$online_characters" =~ ^[0-9]+$ ]] || return 0

    if (( online_characters > human_sessions )); then
        bots_online=$((online_characters - human_sessions))
    else
        bots_online=0
    fi

    printf 'AMP_AZEROTHCORE_METRICS BotsOnline=%s\n' "$bots_online"
}

monitor_signal_exit() {
    # Background monitors normally sleep between checks. A plain TERM sent to a
    # Bash subshell can leave its external `sleep` child holding AMP's console
    # pipe open until the full interval expires. Kill/reap that child so Stop
    # completes immediately after the managed services have shut down.
    if [[ -n "${MONITOR_SLEEP_PID:-}" ]]; then
        kill -TERM "$MONITOR_SLEEP_PID" 2>/dev/null || true
        wait "$MONITOR_SLEEP_PID" 2>/dev/null || true
        MONITOR_SLEEP_PID=""
    fi
    exit 0
}

monitor_sleep() {
    local delay="$1"
    sleep "$delay" &
    MONITOR_SLEEP_PID=$!
    wait "$MONITOR_SLEEP_PID" 2>/dev/null || true
    MONITOR_SLEEP_PID=""
}

start_metrics_monitor() {
    # Standard AzerothCore intentionally publishes no custom metrics. AMP's
    # built-in Active Users list/count remains the single human-player metric.
    if ! is_playerbots_distribution; then
        log "Custom Bots Online metric disabled for non-Playerbots distribution"
        return 0
    fi

    (
        MONITOR_SLEEP_PID=""
        trap monitor_signal_exit TERM INT HUP

        while process_is_running "$WORLD_PID" && [[ ! -f "$READY_MARKER" ]]; do
            monitor_sleep 1
        done
        process_is_running "$WORLD_PID" || exit 0

        # Keep first-boot SQL/import output readable and avoid metrics being spliced
        # into database updater lines. Metrics begin only after AMP readiness.
        monitor_sleep "$METRICS_INTERVAL_SECONDS"
        while process_is_running "$WORLD_PID"; do
            emit_metrics
            monitor_sleep "$METRICS_INTERVAL_SECONDS"
        done
    ) &
    METRICS_PID=$!
    write_pid_record "$METRICS_PID_FILE" "$METRICS_PID"
}

pid_starttime() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}

write_pid_record() {
    local file="$1" pid="$2" starttime
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    starttime="$(pid_starttime "$pid" 2>/dev/null || true)"
    [[ -n "$starttime" ]] || return 0
    printf '%s\t%s\t%s\n' "$pid" "$starttime" "$LIFECYCLE_ID" > "$file"
}

read_pid_record() {
    local file="$1"
    RECORD_PID=""
    RECORD_STARTTIME=""
    RECORD_LIFECYCLE=""
    [[ -r "$file" ]] || return 1
    IFS=$'	 ' read -r RECORD_PID RECORD_STARTTIME RECORD_LIFECYCLE < "$file" || true
    [[ "$RECORD_PID" =~ ^[0-9]+$ ]] || return 1
    return 0
}

process_is_running() {
    local pid="$1" state
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}')"
    [[ "$state" != Z* ]]
}

child_pids() {
    local parent_pid="$1"
    ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent_pid" '$2 == parent { print $1 }'
}

kill_process_tree() {
    local pid="$1" signal_name="${2:-TERM}" child
    [[ -n "$pid" ]] || return 0

    # Kill descendants before their parent. This is important for the metrics
    # and readiness helpers: Bash can be blocked in wait(2) on an external sleep
    # or MySQL CLI child and may not run its TERM trap until that child exits.
    # Leaving that child alive also leaves AMP's console pipe open.
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        kill_process_tree "$child" "$signal_name"
    done < <(child_pids "$pid")

    kill -"$signal_name" "$pid" 2>/dev/null || true
}

process_tree_is_running() {
    local pid="$1" child
    if process_is_running "$pid"; then
        return 0
    fi
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        if process_tree_is_running "$child"; then
            return 0
        fi
    done < <(child_pids "$pid")
    return 1
}

stop_pid_tree_gracefully() {
    local pid="$1" name="$2" timeout_count="${3:-5}"
    [[ -n "$pid" ]] || return

    if ! process_is_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        return
    fi

    log "Stopping $name"
    kill_process_tree "$pid" TERM
    while (( timeout_count-- > 0 )); do
        if ! process_is_running "$pid"; then
            wait "$pid" 2>/dev/null || true
            log "$name stopped"
            return
        fi
        # Reap any child that was created between the initial tree walk and TERM.
        kill_process_tree "$pid" TERM
        sleep 1
    done

    log "$name did not stop in time; killing its remaining process tree"
    kill_process_tree "$pid" KILL
    wait "$pid" 2>/dev/null || true
    log "$name stopped"
}

stop_pid_gracefully() {
    local pid="$1" name="$2" timeout_count="${3:-30}"
    [[ -n "$pid" ]] || return
    if ! process_is_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        return
    fi
    log "Stopping $name"
    kill -TERM "$pid" 2>/dev/null || true
    while (( timeout_count-- > 0 )); do
        if ! process_is_running "$pid"; then
            wait "$pid" 2>/dev/null || true
            return
        fi
        sleep 1
    done
    log "$name did not stop in time; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

stop_mysql_service() {
    local pid="${MYSQL_PID:-}" timeout_count
    if [[ ! "$pid" =~ ^[0-9]+$ && -r "$MYSQL_PID_FILE" ]]; then
        pid="$(tr -dc '0-9' < "$MYSQL_PID_FILE" 2>/dev/null || true)"
    fi

    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! process_is_running "$pid"; then
        rm -f "$MYSQL_SERVICE_PID_FILE" "$MYSQL_PID_FILE" "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" 2>/dev/null || true
        MYSQL_PID=""
        return 0
    fi

    log "Stopping MySQL gracefully"
    if [[ -S "$MYSQL_SOCKET" ]]; then
        timeout --signal=TERM --kill-after=3s 30s \
            env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" \
            "$MYSQL_DIR/bin/mysqladmin" --no-defaults --protocol=socket \
            --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" shutdown \
            >/dev/null 2>&1 || true
    fi

    timeout_count=10
    while (( timeout_count-- > 0 )) && process_is_running "$pid"; do
        sleep 1
    done
    if process_is_running "$pid"; then
        log "MySQL did not finish its graceful shutdown; sending SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        timeout_count=10
        while (( timeout_count-- > 0 )) && process_is_running "$pid"; do
            sleep 1
        done
    fi
    if process_is_running "$pid"; then
        log "MySQL is still running; sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        timeout_count=5
        while (( timeout_count-- > 0 )) && process_is_running "$pid"; do
            sleep 1
        done
    fi

    wait "$pid" 2>/dev/null || true
    rm -f "$MYSQL_SERVICE_PID_FILE" "$MYSQL_PID_FILE" "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" 2>/dev/null || true
    MYSQL_PID=""
    log "MySQL stopped"
}

start_shutdown_watchdog() {
    local supervisor_start world_start timeout_count=50 watchdog_lifecycle=""
    supervisor_start="$(pid_starttime $$ 2>/dev/null || true)"
    world_start="$(pid_starttime "$WORLD_PID" 2>/dev/null || true)"
    [[ -n "$supervisor_start" && -n "$world_start" ]] \
        || fail "Could not record process start times for the shutdown watchdog"

    rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true
    setsid --fork "$WATCHDOG_SCRIPT" \
        --base-dir "$BASE_DIR" \
        --lifecycle-id "$LIFECYCLE_ID" \
        --supervisor-pid "$$" \
        --supervisor-starttime "$supervisor_start" \
        --world-pid "$WORLD_PID" \
        --world-starttime "$world_start" \
        </dev/null

    while (( timeout_count-- > 0 )); do
        if [[ -r "$WATCHDOG_PID_FILE" ]]; then
            read_pid_record "$WATCHDOG_PID_FILE" || true
            watchdog_lifecycle="$RECORD_LIFECYCLE"
            if [[ "$watchdog_lifecycle" == "$LIFECYCLE_ID" ]] && process_is_running "$RECORD_PID"; then
                log "Detached shutdown watchdog armed (PID $RECORD_PID)"
                return 0
            fi
        fi
        sleep 0.1
    done
    fail "Shutdown watchdog failed to start"
}

cleanup() {
    local cleanup_fd watchdog_pid="" timeout_count
    if [[ "$CLEANED_UP" == "true" ]]; then
        return
    fi
    CLEANED_UP="true"
    rm -f "$READY_MARKER" 2>/dev/null || true

    exec {cleanup_fd}>"$CLEANUP_LOCK_FILE"
    if ! flock -w 90 "$cleanup_fd"; then
        log "Could not acquire the shutdown cleanup lock; detached watchdog will continue cleanup"
        return
    fi

    if [[ -r "$CLEANUP_COMPLETE_MARKER" ]] \
        && [[ "$(cat "$CLEANUP_COMPLETE_MARKER" 2>/dev/null || true)" == "$LIFECYCLE_ID" ]]; then
        flock -u "$cleanup_fd" 2>/dev/null || true
        eval "exec ${cleanup_fd}>&-"
        log "Shutdown cleanup was already completed by the detached watchdog"
        return
    fi

    log "Finalizing shutdown: stopping background monitors, worldserver, companion services, authserver, and MySQL"
    stop_pid_tree_gracefully "$READY_PID" "readiness monitor" 3
    READY_PID=""
    rm -f "$READY_PID_FILE" 2>/dev/null || true
    stop_pid_tree_gracefully "$METRICS_PID" "metrics monitor" 3
    METRICS_PID=""
    rm -f "$METRICS_PID_FILE" 2>/dev/null || true
    stop_pid_gracefully "$WORLD_PID" "worldserver" 60
    rm -f "$WORLD_PID_FILE" 2>/dev/null || true
    companion_stop_all || true
    stop_pid_gracefully "$AUTH_PID" "authserver" 30
    AUTH_PID=""
    rm -f "$AUTH_PID_FILE" 2>/dev/null || true
    stop_mysql_service

    printf '%s\n' "$LIFECYCLE_ID" > "$CLEANUP_COMPLETE_MARKER"
    flock -u "$cleanup_fd" 2>/dev/null || true
    eval "exec ${cleanup_fd}>&-"

    # The detached watchdog is normally waiting for this completion marker. Give
    # it a moment to exit; if it does not, stop only that matching helper.
    if read_pid_record "$WATCHDOG_PID_FILE" && [[ "$RECORD_LIFECYCLE" == "$LIFECYCLE_ID" ]]; then
        watchdog_pid="$RECORD_PID"
        timeout_count=30
        while (( timeout_count-- > 0 )) && process_is_running "$watchdog_pid"; do
            sleep 0.1
        done
        if process_is_running "$watchdog_pid"; then
            kill -TERM "$watchdog_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true
    log "Shutdown complete"
}

handle_signal() {
    log "Received a termination signal"
    cleanup
    exit 143
}

trap handle_signal INT TERM HUP
trap cleanup EXIT

if [[ -f "$BASE_DIR/AMP-INSTALLED-VERSION.txt" ]]; then
    log "Installed build:"
    sed 's/^/[AMP\/AzerothCore]   /' "$BASE_DIR/AMP-INSTALLED-VERSION.txt"
fi

start_mysql
verify_azerothcore_database_socket
create_databases
configure_server_files
prepare_openssl_runtime
repair_auth_base_schema
update_realm_record

# The template prepares the official authentication base schema before starting
# authserver, so no bootstrap authserver/restart cycle is necessary. AzerothCore
# performs its normal updates and prepared-statement validation on this single
# start. The auth port is only opened after DB load and realm initialization.
cd "$BIN_DIR"
start_authserver
wait_for_authserver_ready "authserver"

rm -f "$READY_MARKER" 2>/dev/null || true
log "Starting worldserver (AMP console input is attached directly to worldserver stdin)"
# Explicit <&0 prevents Bash's asynchronous-command /dev/null stdin behavior,
# allowing AMP's writable console and ExitString to reach worldserver directly.
env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" OPENSSL_CONF="$OPENSSL_CONF" OPENSSL_MODULES="$OPENSSL_MODULES" \
    "$BIN_DIR/worldserver" -c "$ETC_DIR/worldserver.conf" <&0 &
WORLD_PID=$!
write_pid_record "$WORLD_PID_FILE" "$WORLD_PID"

(
    MONITOR_SLEEP_PID=""
    trap monitor_signal_exit TERM INT HUP
    timeout_count=3600
    while (( timeout_count-- > 0 )); do
        if ! process_is_running "$AUTH_PID"; then
            printf '[AMP/AzerothCore] ERROR: authserver exited while worldserver was starting\n' >&2
            kill -TERM "$WORLD_PID" 2>/dev/null || true
            exit 1
        fi
        if ! process_is_running "$WORLD_PID"; then
            exit 1
        fi
        if port_is_open 127.0.0.1 "$WORLD_PORT"; then
            stable_count="$READY_STABILITY_SECONDS"
            while (( stable_count-- > 0 )); do
                if ! process_is_running "$AUTH_PID" || ! process_is_running "$WORLD_PID" \
                    || ! port_is_open 127.0.0.1 "$WORLD_PORT"; then
                    printf '[AMP/AzerothCore] ERROR: worldserver became unhealthy during the %ss readiness grace period\n' "$READY_STABILITY_SECONDS" >&2
                    exit 1
                fi
                monitor_sleep 1
            done
            emit_server_info
            touch "$READY_MARKER"
            printf 'AMP_AZEROTHCORE_READY\n'
            exit 0
        fi
        monitor_sleep 1
    done
    printf '[AMP/AzerothCore] ERROR: Timed out waiting for worldserver port %s\n' "$WORLD_PORT" >&2
    exit 1
) &
READY_PID=$!
write_pid_record "$READY_PID_FILE" "$READY_PID"
start_metrics_monitor
start_shutdown_watchdog

# Companion services start only after the same stable worldserver readiness
# marker AMP uses. This lets AzerothCore apply character-database migrations
# before a bridge or worker begins polling module tables.
if (( ${#COMPANION_RUNTIME_IDS[@]} > 0 )) \
    && is_true "${AMP_ACORE_MANAGE_COMPANION_SERVICES:-1}"; then
    while process_is_running "$WORLD_PID" && process_is_running "$AUTH_PID" \
        && process_is_running "$READY_PID" && [[ ! -f "$READY_MARKER" ]]; do
        sleep 1
    done
    if [[ -f "$READY_MARKER" ]] && process_is_running "$WORLD_PID"; then
        companion_start_all
    else
        log "Worldserver did not become ready; companion services will not start"
    fi
fi

while process_is_running "$WORLD_PID"; do
    companion_report_unexpected_exits
    sleep 1
done
set +e
wait "$WORLD_PID"
WORLD_STATUS=$?
set -e

log "worldserver exited with status $WORLD_STATUS"
if (( WORLD_STATUS != 0 )); then
    log "Recent AzerothCore logs after unexpected worldserver exit:"
    tail -n 160 "$BASE_DIR/logs/Server.log" >&2 2>/dev/null || true
    tail -n 160 "$BASE_DIR/logs/Errors.log" >&2 2>/dev/null || true
fi
cleanup
trap - EXIT
exit "$WORLD_STATUS"
