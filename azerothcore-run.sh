#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

log() {
    printf '[AMP/AzerothCore] %s\n' "$*"
}

fail() {
    printf '[AMP/AzerothCore] ERROR: %s\n' "$*" >&2
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
DIST_DIR="$BASE_DIR/dist"
BIN_DIR="$DIST_DIR/bin"
ETC_DIR="$DIST_DIR/etc"
MYSQL_DIR="$BASE_DIR/mysql"
MYSQL_DATA_DIR="$BASE_DIR/mysql-data"
MYSQL_RUN_DIR="$BASE_DIR/run/mysqld"
MYSQL_LOG_DIR="$BASE_DIR/logs/mysql"
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"
MYSQL_PID_FILE="$MYSQL_RUN_DIR/mysqld.pid"
WORLD_STDIN_FIFO="$BASE_DIR/run/worldserver.stdin"
MYSQL_BUFFER_POOL_MB="$(numeric_or_default "${AMP_ACORE_MYSQL_BUFFER_POOL_MB:-1024}" 1024)"
METRICS_INTERVAL_SECONDS="$(numeric_or_default "${AMP_ACORE_METRICS_INTERVAL_SECONDS:-60}" 60)"
if (( METRICS_INTERVAL_SECONDS < 10 )); then
    METRICS_INTERVAL_SECONDS=10
fi
SERVER_START_EPOCH="$(date +%s)"
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
DATABASE_USER="$(id -un)"

[[ -x "$BIN_DIR/authserver" ]] || fail "authserver is not installed; run Update first"
[[ -x "$BIN_DIR/worldserver" ]] || fail "worldserver is not installed; run Update first"
[[ -x "$MYSQL_DIR/bin/mysqld" ]] || fail "MySQL is not installed; run Update first"
[[ -f "$ETC_DIR/authserver.conf" ]] || fail "authserver.conf is missing; run Update first"
[[ -f "$ETC_DIR/worldserver.conf" ]] || fail "worldserver.conf is missing; run Update first"
[[ -d "$BIN_DIR/dbc" && -d "$BIN_DIR/maps" && -d "$BIN_DIR/vmaps" && -d "$BIN_DIR/mmaps" ]] \
    || fail "Required client data is missing from dist/bin; enable client-data installation or provide extracted data"

mkdir -p "$MYSQL_RUN_DIR" "$MYSQL_LOG_DIR" "$BASE_DIR/logs" "$BASE_DIR/temp" "$BASE_DIR/run"
export PATH="$MYSQL_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$MYSQL_DIR/lib:$MYSQL_DIR/lib/private:${LD_LIBRARY_PATH:-}"
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

verify_runtime_mysql_linkage() {
    local server_binary linked_mysql unresolved_runtime
    for server_binary in "$BIN_DIR/authserver" "$BIN_DIR/worldserver"; do
        unresolved_runtime="$(ldd "$server_binary" 2>/dev/null | grep 'not found' || true)"
        [[ -z "$unresolved_runtime" ]] \
            || fail "$(basename "$server_binary") has unresolved runtime libraries: $unresolved_runtime"
        linked_mysql="$(ldd "$server_binary" 2>/dev/null | awk '/libmysqlclient\.so/{print $3; exit}')"
        [[ -n "$linked_mysql" && "$linked_mysql" == "$MYSQL_DIR/lib/"* ]] \
            || fail "$(basename "$server_binary") is not using the bundled MySQL client library (resolved '${linked_mysql:-none}'). Run Update to rebuild the server."
    done
}
verify_runtime_mysql_linkage

configure_server_files() {
    local database_auth database_world database_characters database_playerbots playerbots_config
    local start_money_gold start_money_copper cross_faction_value chat_feed_value
    database_auth=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_auth"
    database_world=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_world"
    database_characters=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_characters"
    database_playerbots=".;$MYSQL_SOCKET;$DATABASE_USER;;acore_playerbots"
    start_money_gold="$(numeric_or_default "${AMP_ACORE_START_PLAYER_MONEY_GOLD:-0}" 0)"
    start_money_copper=$((start_money_gold * 10000))
    cross_faction_value="$(boolean_number "${AMP_ACORE_ALLOW_CROSS_FACTION_INTERACTION:-0}")"
    chat_feed_value="$(boolean_number "${AMP_ACORE_ENABLE_CHAT_FEED:-0}")"

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
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "PlayerSaveInterval" "${AC_PLAYER_SAVE_INTERVAL:-900}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "PlayerSave.AdditionalSaves" "${AC_PLAYER_SAVE_ADDITIONAL_SAVES:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Warden.Enabled" "$(boolean_number "${AC_WARDEN_ENABLED:-1}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Network.EnableProxyProtocol" "$(boolean_number "${AMP_ACORE_ENABLE_PROXY_PROTOCOL:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "AllowLoggingIPAddressesInDatabase" "$(boolean_number "${AMP_ACORE_ALLOW_LOGGING_IP_ADDRESSES:-1}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "Allow.IP.Based.Action.Logging" "$(boolean_number "${AC_ALLOW_IP_BASED_ACTION_LOGGING:-0}")"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "MaxCoreStuckTime" "${AC_MAX_CORE_STUCK_TIME:-0}"
    set_conf_value_if_present "$ETC_DIR/worldserver.conf" "ThreadPool" "${AC_THREAD_POOL:-2}"
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
        set_conf_value "$playerbots_config" "PlayerbotsDatabaseInfo" "$(config_string "$database_playerbots")"
        set_conf_value "$playerbots_config" "AiPlayerbot.Enabled" "${AC_AI_PLAYERBOT_ENABLED:-1}"
        set_conf_value "$playerbots_config" "AiPlayerbot.RandomBotAutologin" "${AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN:-1}"
        set_conf_value "$playerbots_config" "AiPlayerbot.MinRandomBots" "${AC_AI_PLAYERBOT_MIN_RANDOM_BOTS:-100}"
        set_conf_value "$playerbots_config" "AiPlayerbot.MaxRandomBots" "${AC_AI_PLAYERBOT_MAX_RANDOM_BOTS:-100}"
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
        set_conf_value "$playerbots_config" "AiPlayerbot.CommandServerPort" "0"
    done
}
MYSQL_PID=""
AUTH_PID=""
WORLD_PID=""
STDIN_PID=""
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
    "$MYSQL_DIR/bin/mysqladmin" --protocol=socket --socket="$MYSQL_SOCKET" --user="$DATABASE_USER" ping >/dev/null 2>&1
}

start_mysql() {
    local timeout_count=180
    if mysql_ready; then
        log "Instance-local MySQL is already running"
        return
    fi
    rm -f "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" "$MYSQL_PID_FILE"
    mysql_server_args
    log "Starting instance-local MySQL"
    "$MYSQL_DIR/bin/mysqld" "${MYSQL_SERVER_ARGS[@]}" &
    MYSQL_PID=$!

    while (( timeout_count-- > 0 )); do
        if mysql_ready; then
            log "MySQL is ready"
            return
        fi
        if ! kill -0 "$MYSQL_PID" 2>/dev/null; then
            tail -n 100 "$MYSQL_LOG_DIR/mysql-error.log" >&2 || true
            fail "MySQL exited during startup"
        fi
        sleep 1
    done
    tail -n 100 "$MYSQL_LOG_DIR/mysql-error.log" >&2 || true
    fail "Timed out waiting for MySQL"
}

create_databases() {
    "$MYSQL_DIR/bin/mysql" --protocol=socket --socket="$MYSQL_SOCKET" --user="$DATABASE_USER" <<'SQL'
CREATE DATABASE IF NOT EXISTS acore_auth CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_characters CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_world CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_playerbots CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
}

start_authserver() {
    log "Starting authserver"
    "$BIN_DIR/authserver" -c "$ETC_DIR/authserver.conf" </dev/null &
    AUTH_PID=$!
}

wait_for_auth_database() {
    local timeout_count=900 dead_checks=0
    log "Waiting for authserver to create/update the authentication database"
    while (( timeout_count-- > 0 )); do
        if "$MYSQL_DIR/bin/mysql" --protocol=socket --socket="$MYSQL_SOCKET" --user="$DATABASE_USER" \
            --batch --skip-column-names -e 'SELECT id FROM acore_auth.realmlist LIMIT 1' >/dev/null 2>&1; then
            return
        fi
        if [[ -n "$AUTH_PID" ]] && ! kill -0 "$AUTH_PID" 2>/dev/null; then
            ((dead_checks+=1))
            if (( dead_checks > 10 )); then
                wait "$AUTH_PID" 2>/dev/null || true
                AUTH_PID=""
                fail "authserver exited before the authentication database became ready"
            fi
        fi
        sleep 1
    done
    fail "Timed out waiting for acore_auth.realmlist"
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

    "$MYSQL_DIR/bin/mysql" --protocol=socket --socket="$MYSQL_SOCKET" --user="$DATABASE_USER" <<SQL
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
    "$MYSQL_DIR/bin/mysql" --protocol=socket --socket="$MYSQL_SOCKET" --user="$DATABASE_USER" \
        --batch --skip-column-names --connect-timeout=3 -e "$query" 2>/dev/null | head -n1
}

emit_server_info() {
    local state_dir distribution core_ref core_commit modules client_data mysql_version modules_list
    state_dir="$BASE_DIR/.amp-state"
    distribution="$(cat "$state_dir/distribution" 2>/dev/null || printf 'unknown')"
    core_ref="$(cat "$state_dir/core-ref" 2>/dev/null || printf 'unknown')"
    core_commit="$(cat "$state_dir/core-commit" 2>/dev/null || printf 'unknown')"
    core_commit="${core_commit:0:12}"
    modules_list="$(cat "$state_dir/managed-modules" 2>/dev/null || true)"
    if [[ -n "$modules_list" ]]; then
        modules="$(printf '%s\n' "$modules_list" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    else
        modules=0
    fi
    client_data="$(cat "$state_dir/client-data-version" 2>/dev/null || printf 'manual')"
    mysql_version="$(cat "$state_dir/mysql-version" 2>/dev/null || printf 'unknown')"
    printf 'AMP_AZEROTHCORE_INFO Distribution=%s CoreRef=%s CoreCommit=%s Modules=%s ClientData=%s MySQL=%s\n' \
        "$(sanitize_info_value "$distribution")" \
        "$(sanitize_info_value "$core_ref")" \
        "$(sanitize_info_value "$core_commit")" \
        "$modules" \
        "$(sanitize_info_value "$client_data")" \
        "$(sanitize_info_value "$mysql_version")"
}

emit_metrics() {
    local human_sessions online_characters automated_characters accounts_total characters_total uptime_minutes now
    human_sessions="$(mysql_scalar 'SELECT COUNT(*) FROM acore_auth.account WHERE online <> 0;' || true)"
    online_characters="$(mysql_scalar 'SELECT COUNT(*) FROM acore_characters.characters WHERE online <> 0;' || true)"
    accounts_total="$(mysql_scalar 'SELECT COUNT(*) FROM acore_auth.account;' || true)"
    characters_total="$(mysql_scalar 'SELECT COUNT(*) FROM acore_characters.characters;' || true)"
    [[ "$human_sessions" =~ ^[0-9]+$ ]] || return 0
    [[ "$online_characters" =~ ^[0-9]+$ ]] || return 0
    [[ "$accounts_total" =~ ^[0-9]+$ ]] || return 0
    [[ "$characters_total" =~ ^[0-9]+$ ]] || return 0
    if (( online_characters > human_sessions )); then
        automated_characters=$((online_characters - human_sessions))
    else
        automated_characters=0
    fi
    now="$(date +%s)"
    uptime_minutes=$(((now - SERVER_START_EPOCH) / 60))
    printf 'AMP_AZEROTHCORE_METRICS HumanSessions=%s AutomatedCharacters=%s OnlineCharacters=%s AccountsTotal=%s CharactersTotal=%s UptimeMinutes=%s\n' \
        "$human_sessions" "$automated_characters" "$online_characters" "$accounts_total" "$characters_total" "$uptime_minutes"
}

start_metrics_monitor() {
    (
        while kill -0 "$WORLD_PID" 2>/dev/null; do
            emit_metrics
            sleep "$METRICS_INTERVAL_SECONDS"
        done
    ) &
    METRICS_PID=$!
}

stop_pid_gracefully() {
    local pid="$1" name="$2" timeout_count="${3:-30}"
    [[ -n "$pid" ]] || return
    kill -0 "$pid" 2>/dev/null || return
    log "Stopping $name"
    kill -TERM "$pid" 2>/dev/null || true
    while (( timeout_count-- > 0 )); do
        kill -0 "$pid" 2>/dev/null || return
        sleep 1
    done
    log "$name did not stop in time; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
    if [[ "$CLEANED_UP" == "true" ]]; then
        return
    fi
    CLEANED_UP="true"

    if [[ -n "$READY_PID" ]]; then
        kill "$READY_PID" 2>/dev/null || true
        wait "$READY_PID" 2>/dev/null || true
    fi
    if [[ -n "$METRICS_PID" ]]; then
        kill "$METRICS_PID" 2>/dev/null || true
        wait "$METRICS_PID" 2>/dev/null || true
    fi
    stop_pid_gracefully "$WORLD_PID" "worldserver" 60
    stop_pid_gracefully "$AUTH_PID" "authserver" 30
    if [[ -n "$STDIN_PID" ]]; then
        kill "$STDIN_PID" 2>/dev/null || true
        wait "$STDIN_PID" 2>/dev/null || true
    fi
    rm -f "$WORLD_STDIN_FIFO"

    if mysql_ready; then
        log "Stopping MySQL"
        "$MYSQL_DIR/bin/mysqladmin" --protocol=socket --socket="$MYSQL_SOCKET" --user="$DATABASE_USER" shutdown >/dev/null 2>&1 || true
    fi
    if [[ -n "$MYSQL_PID" ]]; then
        wait "$MYSQL_PID" 2>/dev/null || true
    fi
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
create_databases
configure_server_files

cd "$BIN_DIR"
start_authserver
wait_for_auth_database
update_realm_record

if [[ -z "$AUTH_PID" ]] || ! kill -0 "$AUTH_PID" 2>/dev/null; then
    log "Restarting authserver after first-run database initialization"
    AUTH_PID=""
    start_authserver
    sleep 2
    kill -0 "$AUTH_PID" 2>/dev/null || fail "authserver failed to restart"
fi

rm -f "$WORLD_STDIN_FIFO"
mkfifo "$WORLD_STDIN_FIFO"
cat > "$WORLD_STDIN_FIFO" &
STDIN_PID=$!

log "Starting worldserver"
"$BIN_DIR/worldserver" -c "$ETC_DIR/worldserver.conf" < "$WORLD_STDIN_FIFO" &
WORLD_PID=$!

(
    timeout_count=3600
    while (( timeout_count-- > 0 )); do
        if ! kill -0 "$WORLD_PID" 2>/dev/null; then
            exit 1
        fi
        if port_is_open 127.0.0.1 "$WORLD_PORT"; then
            emit_server_info
            printf 'AMP_AZEROTHCORE_READY\n'
            exit 0
        fi
        sleep 1
    done
    printf '[AMP/AzerothCore] ERROR: Timed out waiting for worldserver port %s\n' "$WORLD_PORT" >&2
    exit 1
) &
READY_PID=$!
start_metrics_monitor

set +e
wait "$WORLD_PID"
WORLD_STATUS=$?
set -e
WORLD_PID=""

log "worldserver exited with status $WORLD_STATUS"
cleanup
trap - EXIT
exit "$WORLD_STATUS"
