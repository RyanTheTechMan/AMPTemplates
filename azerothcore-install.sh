#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

log() {
    printf '[AMP/AzerothCore installer] %s\n' "$*"
}

fail() {
    printf '[AMP/AzerothCore installer] ERROR: %s\n' "$*" >&2
    exit 1
}

is_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

sql_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

BASE_DIR=""
DISTRIBUTION="standard-master"
CUSTOM_CORE_REPOSITORY=""
CUSTOM_CORE_REF=""
CUSTOM_PLAYERBOTS_REPOSITORY=""
CUSTOM_PLAYERBOTS_REF=""
ADDITIONAL_MODULES=""
BUILD_TYPE="RelWithDebInfo"
BUILD_THREADS="0"
FORCE_CLEAN_BUILD="false"
EXTRA_CMAKE_OPTIONS=""
INSTALL_CLIENT_DATA="true"
CLIENT_DATA_VERSION="v20.0"
MYSQL_RELEASE="8.4"
CUSTOM_MYSQL_VERSION=""
MYSQL_BUFFER_POOL_MB="1024"
INSTALLER_TEMPLATE_VERSION="20"
EXPECTED_TEMPLATE_VERSION=""

while (($#)); do
    case "$1" in
        --base-dir) BASE_DIR="${2:-}"; shift 2 ;;
        --distribution) DISTRIBUTION="${2:-}"; shift 2 ;;
        --custom-core-repository) CUSTOM_CORE_REPOSITORY="${2:-}"; shift 2 ;;
        --custom-core-ref) CUSTOM_CORE_REF="${2:-}"; shift 2 ;;
        --custom-playerbots-repository) CUSTOM_PLAYERBOTS_REPOSITORY="${2:-}"; shift 2 ;;
        --custom-playerbots-ref) CUSTOM_PLAYERBOTS_REF="${2:-}"; shift 2 ;;
        --additional-modules) ADDITIONAL_MODULES="${2:-}"; shift 2 ;;
        --build-type) BUILD_TYPE="${2:-}"; shift 2 ;;
        --build-threads) BUILD_THREADS="${2:-}"; shift 2 ;;
        --force-clean-build) FORCE_CLEAN_BUILD="${2:-}"; shift 2 ;;
        --extra-cmake-options) EXTRA_CMAKE_OPTIONS="${2:-}"; shift 2 ;;
        --install-client-data) INSTALL_CLIENT_DATA="${2:-}"; shift 2 ;;
        --client-data-version) CLIENT_DATA_VERSION="${2:-}"; shift 2 ;;
        --mysql-release) MYSQL_RELEASE="${2:-}"; shift 2 ;;
        --custom-mysql-version) CUSTOM_MYSQL_VERSION="${2:-}"; shift 2 ;;
        --mysql-buffer-pool-mb) MYSQL_BUFFER_POOL_MB="${2:-}"; shift 2 ;;
        --expected-template-version) EXPECTED_TEMPLATE_VERSION="${2:-}"; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -n "$BASE_DIR" ]] || fail "--base-dir is required"
mkdir -p "$BASE_DIR"
BASE_DIR="$(cd "$BASE_DIR" && pwd -P)"
if [[ -n "$EXPECTED_TEMPLATE_VERSION" && "$EXPECTED_TEMPLATE_VERSION" != "$INSTALLER_TEMPLATE_VERSION" ]]; then
    fail "Template/runtime version mismatch: AMP expected v$EXPECTED_TEMPLATE_VERSION but downloaded installer v$INSTALLER_TEMPLATE_VERSION. Update the configured template repository/ref before retrying."
fi
log "Installer v$INSTALLER_TEMPLATE_VERSION starting"

[[ -f "$BASE_DIR/azerothcore-run.sh" ]] \
    || fail "The AzerothCore launcher was not downloaded before the installer"
if ! grep -Fq 'LAUNCHER_TEMPLATE_VERSION="20"' "$BASE_DIR/azerothcore-run.sh"; then
    fail "Template/runtime version mismatch: installer v$INSTALLER_TEMPLATE_VERSION did not receive launcher v20. Update the configured template repository/ref before retrying."
fi
[[ -f "$BASE_DIR/azerothcore-watchdog.sh" ]] \
    || fail "The AzerothCore shutdown watchdog was not downloaded before the installer"
if ! grep -Fq 'WATCHDOG_TEMPLATE_VERSION="20"' "$BASE_DIR/azerothcore-watchdog.sh"; then
    fail "Template/runtime version mismatch: installer v$INSTALLER_TEMPLATE_VERSION did not receive shutdown watchdog v20. Update the configured template repository/ref before retrying."
fi
[[ -f "$BASE_DIR/azerothcore-companions.sh" ]] \
    || fail "The managed companion service library was not downloaded before the installer"
if ! grep -Fq 'COMPANION_LIBRARY_VERSION="20"' "$BASE_DIR/azerothcore-companions.sh"; then
    fail "Template/runtime version mismatch: installer v$INSTALLER_TEMPLATE_VERSION did not receive companion library v20. Update the configured template repository/ref before retrying."
fi

case "$BUILD_TYPE" in
    Release|RelWithDebInfo|Debug) ;;
    *) fail "Unsupported build type '$BUILD_TYPE'" ;;
esac
[[ "$BUILD_THREADS" =~ ^[0-9]+$ ]] || fail "Parallel Build Jobs must be a non-negative integer"
[[ "$MYSQL_BUFFER_POOL_MB" =~ ^[0-9]+$ ]] || fail "MySQL buffer pool must be an integer"
(( MYSQL_BUFFER_POOL_MB >= 256 )) || fail "MySQL buffer pool must be at least 256 MB"

required_commands=(git cmake ninja clang clang++ ccache curl jq unzip tar xz sed awk grep find nproc ps sha256sum nm ldd readlink openssl dpkg-query dirname setsid flock timeout python3)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command '$command_name' is missing from the AMP container"
done

# Debian 13 splits OpenSSL's legacy algorithms into a separate provider package.
# Locate the module from Debian's package database rather than from `openssl` on
# PATH: after MySQL is installed its portable bin directory may contain Oracle's
# own OpenSSL executable with a non-Debian MODULESDIR.
SYSTEM_OPENSSL="/usr/bin/openssl"
[[ -x "$SYSTEM_OPENSSL" ]] || fail "Debian system OpenSSL is missing at $SYSTEM_OPENSSL"
OPENSSL_LEGACY_MODULE="$(dpkg-query -L openssl-provider-legacy 2>/dev/null | awk '/\/legacy\.so$/ {print; exit}')"
if [[ -z "$OPENSSL_LEGACY_MODULE" ]]; then
    OPENSSL_LEGACY_MODULE="$(find /usr/lib /lib -type f -path '*/ossl-modules/legacy.so' -print -quit 2>/dev/null || true)"
fi
[[ -n "$OPENSSL_LEGACY_MODULE" && -r "$OPENSSL_LEGACY_MODULE" ]] \
    || fail "Debian OpenSSL legacy provider is missing. Refresh/recreate the AMP container so openssl-provider-legacy is installed."
OPENSSL_MODULE_DIR="$(dirname "$OPENSSL_LEGACY_MODULE")"
log "OpenSSL legacy provider dependency verified: $OPENSSL_LEGACY_MODULE"

SOURCE_DIR="$BASE_DIR/source"
BUILD_DIR="$BASE_DIR/build"
DIST_DIR="$BASE_DIR/dist"
STATE_DIR="$BASE_DIR/state"
MYSQL_DIR="$BASE_DIR/mysql"
MYSQL_DATA_DIR="$BASE_DIR/mysql-data"
MYSQL_RUN_DIR="$BASE_DIR/run/mysqld"
MYSQL_LOG_DIR="$BASE_DIR/logs/mysql"
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"
MYSQL_PID_FILE="$MYSQL_RUN_DIR/mysqld.pid"
MYSQL_COMPAT_DIR="$MYSQL_DIR/compat"
MYSQL_CLIENT_RUNTIME_DIR="$BASE_DIR/runtime/mysql-client"
LEGACY_MYSQL_PASSWORD_FILE="$STATE_DIR/mysql-runtime-password"

# shellcheck source=azerothcore-companions.sh
source "$BASE_DIR/azerothcore-companions.sh"
[[ "$COMPANION_LIBRARY_VERSION" == "$INSTALLER_TEMPLATE_VERSION" ]] \
    || fail "Template/runtime version mismatch between installer and companion library"

# AzerothCore documents "." as the Unix-socket host marker. Current AzerothCore
# releases have an upstream bug where the first successful socket connection
# mutates that marker to "localhost", causing later pool connections to fall back
# to the MySQL client's default socket. MYSQL_UNIX_PORT pins that fallback to this
# instance-private socket without patching AzerothCore source.
export MYSQL_UNIX_PORT="$MYSQL_SOCKET"

# Oracle's generic MySQL binaries require the historical libaio.so.1 SONAME.
# Debian 13 renamed the system library to libaio.so.1t64. This template is
# x86_64-only, where time_t was already 64-bit, so a local compatibility name
# can safely point at Debian 13's system library without modifying the container.
MYSQL_LD_LIBRARY_PATH="$MYSQL_COMPAT_DIR:$MYSQL_DIR/lib:$MYSQL_DIR/lib/private"
ACORE_LD_LIBRARY_PATH="$MYSQL_COMPAT_DIR:$MYSQL_CLIENT_RUNTIME_DIR"

# Keep Oracle MySQL's private runtime libraries scoped to MySQL processes only.
# Do not export this globally: doing so can make AzerothCore load Oracle's bundled
# OpenSSL instead of Debian's OpenSSL/provider modules.
mysql_env() {
    env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" "$@"
}
mysql_cli() {
    mysql_env "$MYSQL_DIR/bin/mysql" "$@"
}
mysqladmin_cli() {
    mysql_env "$MYSQL_DIR/bin/mysqladmin" "$@"
}
mysqld_cli() {
    mysql_env "$MYSQL_DIR/bin/mysqld" "$@"
}

mkdir -p "$STATE_DIR" "$DIST_DIR" "$MYSQL_DATA_DIR" "$MYSQL_RUN_DIR" "$MYSQL_LOG_DIR" \
    "$BASE_DIR/logs" "$BASE_DIR/temp" "$BASE_DIR/ccache"
chmod 700 "$MYSQL_DATA_DIR" "$MYSQL_RUN_DIR" 2>/dev/null || true

ensure_servers_are_stopped() {
    local process_pid process_command
    while IFS=' ' read -r process_pid process_command; do
        [[ -n "$process_pid" ]] || continue
        case "$process_command" in
            "$DIST_DIR/bin/worldserver"*|"$DIST_DIR/bin/authserver"*|"$BASE_DIR/azerothcore-run.sh"*|"$BASE_DIR/services/"*|*"$SOURCE_DIR/modules/"*/tools/llm_chatter_bridge.py*)
                fail "AzerothCore is still running in this AMP instance. Stop the instance before running Update."
                ;;
        esac
    done < <(ps -eo pid=,args=)
}
ensure_servers_are_stopped

CORE_REPOSITORY=""
CORE_REF=""
PLAYERBOTS_ENABLED="false"
PLAYERBOTS_REPOSITORY=""
PLAYERBOTS_REF=""

case "$DISTRIBUTION" in
    standard-master)
        CORE_REPOSITORY="https://github.com/azerothcore/azerothcore-wotlk.git"
        CORE_REF="master"
        ;;
    standard-v4.0.0)
        CORE_REPOSITORY="https://github.com/azerothcore/azerothcore-wotlk.git"
        CORE_REF="v4.0.0"
        ;;
    standard-v3.0.0)
        CORE_REPOSITORY="https://github.com/azerothcore/azerothcore-wotlk.git"
        CORE_REF="v3.0.0"
        ;;
    standard-custom)
        CORE_REPOSITORY="${CUSTOM_CORE_REPOSITORY:-https://github.com/azerothcore/azerothcore-wotlk.git}"
        CORE_REF="${CUSTOM_CORE_REF:-master}"
        ;;
    playerbots-stable)
        CORE_REPOSITORY="https://github.com/mod-playerbots/azerothcore-wotlk.git"
        CORE_REF="Playerbot"
        PLAYERBOTS_ENABLED="true"
        PLAYERBOTS_REPOSITORY="https://github.com/mod-playerbots/mod-playerbots.git"
        PLAYERBOTS_REF="master"
        ;;
    playerbots-testing)
        CORE_REPOSITORY="https://github.com/mod-playerbots/azerothcore-wotlk.git"
        CORE_REF="test-staging"
        PLAYERBOTS_ENABLED="true"
        PLAYERBOTS_REPOSITORY="https://github.com/mod-playerbots/mod-playerbots.git"
        PLAYERBOTS_REF="test-staging"
        ;;
    playerbots-v16)
        CORE_REPOSITORY="https://github.com/mod-playerbots/azerothcore-wotlk.git"
        CORE_REF="Playerbot_v16"
        PLAYERBOTS_ENABLED="true"
        PLAYERBOTS_REPOSITORY="https://github.com/mod-playerbots/mod-playerbots.git"
        PLAYERBOTS_REF="master_v16"
        ;;
    playerbots-custom)
        CORE_REPOSITORY="${CUSTOM_CORE_REPOSITORY:-https://github.com/mod-playerbots/azerothcore-wotlk.git}"
        CORE_REF="${CUSTOM_CORE_REF:-Playerbot}"
        PLAYERBOTS_ENABLED="true"
        PLAYERBOTS_REPOSITORY="${CUSTOM_PLAYERBOTS_REPOSITORY:-https://github.com/mod-playerbots/mod-playerbots.git}"
        PLAYERBOTS_REF="${CUSTOM_PLAYERBOTS_REF:-master}"
        ;;
    *) fail "Unsupported Server Distribution '$DISTRIBUTION'" ;;
esac

validate_repository_url() {
    local repository_url="$1"
    [[ "$repository_url" =~ ^https://[^[:space:]]+$ ]] \
        || fail "Only whitespace-free HTTPS Git repository URLs are supported: $repository_url"
}
validate_repository_url "$CORE_REPOSITORY"
[[ -n "$CORE_REF" ]] || fail "The selected core Git ref is empty"
[[ "$CORE_REF" != -* ]] || fail "Core Git refs may not begin with a dash"
if is_true "$PLAYERBOTS_ENABLED"; then
    validate_repository_url "$PLAYERBOTS_REPOSITORY"
    [[ "$PLAYERBOTS_REF" != -* ]] || fail "Playerbots Git refs may not begin with a dash"
fi

MYSQL_STARTED_HERE="false"
MYSQL_PID=""

stop_temporary_mysql() {
    if is_true "$MYSQL_STARTED_HERE" && [[ -S "$MYSQL_SOCKET" ]]; then
        local database_user
        database_user="$(id -un)"
        mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" shutdown >/dev/null 2>&1 \
            || mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user=root --password='' shutdown >/dev/null 2>&1 \
            || true
    fi
    if [[ -n "$MYSQL_PID" ]]; then
        wait "$MYSQL_PID" 2>/dev/null || true
    fi
}
trap stop_temporary_mysql EXIT

determine_mysql_version() {
    local version="$CUSTOM_MYSQL_VERSION"
    if [[ -z "$version" ]]; then
        log "Resolving the latest MySQL $MYSQL_RELEASE patch release" >&2
        version="$(curl -fsSL --retry 3 "https://endoflife.date/api/v1/products/mysql/releases/$MYSQL_RELEASE" | jq -er '.result.latest.name')" \
            || fail "Could not resolve the latest MySQL $MYSQL_RELEASE release; set Exact MySQL Version explicitly"
    fi
    [[ "$version" =~ ^(8|9)\.[0-9]+\.[0-9]+$ ]] || fail "Invalid MySQL version '$version'"
    printf '%s' "$version"
}

install_mysql() {
    local target_version installed_version minor_version archive_url temporary_dir archive_file extracted_dir database_user
    database_user="$(id -un)"
    if [[ -x "$MYSQL_DIR/bin/mysqladmin" && -S "$MYSQL_SOCKET" ]] \
        && { mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" ping >/dev/null 2>&1 \
            || mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user=root --password='' ping >/dev/null 2>&1; }; then
        fail "The instance-local MySQL server is still running. Stop the AMP instance before running Update."
    fi

    target_version="$(determine_mysql_version)"
    installed_version=""
    if [[ -x "$MYSQL_DIR/bin/mysqld" ]]; then
        installed_version="$(mysqld_cli --version 2>/dev/null | sed -n 's/.*Ver \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)"
    fi
    if [[ "$installed_version" == "$target_version" ]]; then
        log "MySQL $target_version is already installed"
        printf '%s\n' "$target_version" > "$STATE_DIR/mysql-version"
        return
    fi

    minor_version="${target_version%.*}"
    archive_url="https://cdn.mysql.com/Downloads/MySQL-$minor_version/mysql-$target_version-linux-glibc2.28-x86_64.tar.xz"
    temporary_dir="$(mktemp -d "$BASE_DIR/.mysql-update.XXXXXX")"
    archive_file="$temporary_dir/mysql.tar.xz"
    extracted_dir="$temporary_dir/extracted"
    mkdir -p "$extracted_dir"

    log "Downloading portable MySQL $target_version"
    curl -fL --retry 3 --connect-timeout 30 -o "$archive_file" "$archive_url" \
        || fail "Could not download $archive_url"
    tar -xf "$archive_file" -C "$extracted_dir" --strip-components=1
    [[ -x "$extracted_dir/bin/mysqld" ]] || fail "Downloaded MySQL archive did not contain bin/mysqld"

    rm -rf "$BASE_DIR/mysql.previous"
    if [[ -d "$MYSQL_DIR" ]]; then
        mv "$MYSQL_DIR" "$BASE_DIR/mysql.previous"
    fi
    mv "$extracted_dir" "$MYSQL_DIR"
    rm -rf "$BASE_DIR/mysql.previous" "$temporary_dir"
    printf '%s\n' "$target_version" > "$STATE_DIR/mysql-version"
    log "Installed MySQL $target_version"
}

ensure_mysql_libaio_compat() {
    local system_libaio unresolved
    [[ "$(uname -m)" == "x86_64" ]] \
        || fail "The Debian 13 libaio compatibility shim is only validated for x86_64"

    mkdir -p "$MYSQL_COMPAT_DIR"

    system_libaio="$(find /lib /usr/lib \
        \( -name 'libaio.so.1t64' -o -name 'libaio.so.1t64.*' \) \
        -print -quit 2>/dev/null || true)"
    [[ -n "$system_libaio" ]] \
        || fail "Debian 13 libaio1t64 is missing. Ensure the template's Container Packages were installed."
    system_libaio="$(readlink -f "$system_libaio")"
    [[ -f "$system_libaio" ]] || fail "Could not resolve Debian 13's libaio1t64 shared library"

    rm -f "$MYSQL_COMPAT_DIR/libaio.so.1"
    ln -s "$system_libaio" "$MYSQL_COMPAT_DIR/libaio.so.1"

    if ! nm -D "$MYSQL_COMPAT_DIR/libaio.so.1" 2>/dev/null | grep -Eq '[[:space:]]io_submit(@@[^[:space:]]+)?$'; then
        fail "Debian 13 libaio compatibility library does not export io_submit"
    fi
    if ! nm -D "$MYSQL_COMPAT_DIR/libaio.so.1" 2>/dev/null | grep -Eq '[[:space:]]io_getevents(@@[^[:space:]]+)?$'; then
        fail "Debian 13 libaio compatibility library does not export io_getevents"
    fi

    unresolved="$(env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" ldd "$MYSQL_DIR/bin/mysqld" 2>/dev/null | grep 'not found' || true)"
    [[ -z "$unresolved" ]] \
        || fail "Portable MySQL still has unresolved runtime dependencies after preparing libaio compatibility: $unresolved"

    mysqld_cli --version >/dev/null 2>&1 \
        || fail "Portable MySQL could not start after preparing Debian 13 libaio compatibility"

    log "Prepared Debian 13 libaio compatibility for portable MySQL"
}

find_mysql_client_library() {
    local candidate
    for candidate in \
        "$MYSQL_DIR/lib/libmysqlclient.so" \
        "$MYSQL_DIR/lib/libmysqlclient.so."*; do
        if [[ -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    fail "Portable MySQL does not contain lib/libmysqlclient.so; reinstall MySQL or choose another MySQL release"
}

verify_portable_mysql_toolchain() {
    local mysql_client_library mysql_config_version unresolved
    [[ -x "$MYSQL_DIR/bin/mysql_config" ]] || fail "Portable MySQL is missing bin/mysql_config"
    [[ -f "$MYSQL_DIR/include/mysql.h" ]] || fail "Portable MySQL is missing include/mysql.h"
    mysql_client_library="$(find_mysql_client_library)"
    mysql_config_version="$(mysql_env "$MYSQL_DIR/bin/mysql_config" --version 2>/dev/null || true)"
    [[ -n "$mysql_config_version" ]] || fail "Portable MySQL mysql_config could not report its version"

    log "MySQL build preflight: version $mysql_config_version"
    log "MySQL build preflight: headers $MYSQL_DIR/include"
    log "MySQL build preflight: client library $mysql_client_library"

    # Current AzerothCore uses this MySQL 8.4 client symbol. Only require it when
    # the selected source tree actually references it, which keeps historical refs usable.
    if grep -q 'mysql_stmt_bind_named_param' "$SOURCE_DIR/src/server/database/Database/MySQLConnection.cpp" 2>/dev/null; then
        if ! nm -D "$mysql_client_library" 2>/dev/null \
            | grep -Eq '[[:space:]]mysql_stmt_bind_named_param(@@[^[:space:]]+)?$'; then
            fail "The selected AzerothCore source requires mysql_stmt_bind_named_param, but the bundled MySQL client library does not export it. Use MySQL 8.4 or a compatible newer client library."
        fi
    fi

    unresolved="$(LD_LIBRARY_PATH="$MYSQL_COMPAT_DIR:$MYSQL_DIR/lib:$MYSQL_DIR/lib/private:${LD_LIBRARY_PATH:-}" ldd "$mysql_client_library" 2>/dev/null | grep 'not found' || true)"
    [[ -z "$unresolved" ]] || fail "Portable MySQL client library has unresolved runtime dependencies: $unresolved"
    printf '%s\n' "$mysql_client_library" > "$STATE_DIR/mysql-client-library"
}

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

start_temporary_mysql() {
    local timeout_count=180 database_user
    database_user="$(id -un)"
    if mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" ping >/dev/null 2>&1; then
        log "Using the already-running instance-local MySQL server"
        return
    fi

    rm -f "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" "$MYSQL_PID_FILE"
    mysql_server_args
    log "Starting MySQL temporarily for database initialization"
    env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" "$MYSQL_DIR/bin/mysqld" "${MYSQL_SERVER_ARGS[@]}" &
    MYSQL_PID=$!
    MYSQL_STARTED_HERE="true"

    while (( timeout_count-- > 0 )); do
        if mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user=root --password='' ping >/dev/null 2>&1 \
            || mysqladmin_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" ping >/dev/null 2>&1; then
            return
        fi
        if ! kill -0 "$MYSQL_PID" 2>/dev/null; then
            tail -n 100 "$MYSQL_LOG_DIR/mysql-error.log" >&2 || true
            fail "MySQL exited during initialization"
        fi
        sleep 1
    done
    tail -n 100 "$MYSQL_LOG_DIR/mysql-error.log" >&2 || true
    fail "Timed out waiting for MySQL to start"
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
    (( count > 0 )) || fail "Bundled MySQL client libraries are missing after installation"
    log "Prepared isolated AzerothCore MySQL client runtime: $MYSQL_CLIENT_RUNTIME_DIR"
}

initialize_mysql_data() {
    if [[ ! -f "$MYSQL_DATA_DIR/mysql.ibd" ]]; then
        log "Initializing the instance-local MySQL data directory"
        rm -rf "$MYSQL_DATA_DIR"/*
        local -a initialize_args=(
            --no-defaults
            --initialize-insecure
            "--basedir=$MYSQL_DIR"
            "--datadir=$MYSQL_DATA_DIR"
            "--log-error=$MYSQL_LOG_DIR/mysql-initialize.log"
        )
        if (( EUID == 0 )); then
            initialize_args+=(--user=root)
        fi
        mysqld_cli "${initialize_args[@]}"
    fi

    start_temporary_mysql
    local database_user escaped_database_user
    database_user="$(id -un)"
    escaped_database_user="$(sql_escape "$database_user")"

    if mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user=root --password='' -e 'SELECT 1' >/dev/null 2>&1; then
        log "Securing the initial MySQL accounts"
        mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user=root --password='' <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
CREATE USER IF NOT EXISTS '$escaped_database_user'@'localhost' IDENTIFIED WITH auth_socket;
ALTER USER '$escaped_database_user'@'localhost' IDENTIFIED WITH auth_socket;
GRANT ALL PRIVILEGES ON *.* TO '$escaped_database_user'@'localhost' WITH GRANT OPTION;
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
    fi

    mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" <<'SQL'
CREATE DATABASE IF NOT EXISTS acore_auth CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_characters CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_world CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS acore_playerbots CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

    # Remove the short-lived earlier TCP-account experiment if this is an upgraded test
    # instance. Socket peer credentials are now the only AzerothCore DB auth path.
    mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" \
        -e "DROP USER IF EXISTS 'acore_amp'@'127.0.0.1'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
    rm -f "$LEGACY_MYSQL_PASSWORD_FILE"

    local auth_socket_status
    auth_socket_status="$(mysql_cli --protocol=socket --socket="$MYSQL_SOCKET" --user="$database_user" \
        --batch --skip-column-names \
        -e "SELECT PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME='auth_socket';" 2>/dev/null | head -n1)"
    [[ "$auth_socket_status" == "ACTIVE" ]] \
        || fail "MySQL auth_socket is not active; the bundled server cannot provide passwordless Unix-socket authentication"

    # Verify both paths used by AzerothCore's current socket implementation:
    # 1) the documented explicit socket, and 2) the localhost fallback triggered
    # after its connection-info mutation bug. MYSQL_UNIX_PORT must route both to
    # this same private socket.
    mysql_cli --no-defaults --protocol=socket --socket="$MYSQL_SOCKET" \
        --user="$database_user" --connect-timeout=5 -e 'SELECT 1' >/dev/null 2>&1 \
        || fail "Passwordless auth_socket login failed through the explicit instance socket"

    MYSQL_UNIX_PORT="$MYSQL_SOCKET" mysql_cli --no-defaults --protocol=socket \
        --host=localhost --user="$database_user" --connect-timeout=5 -e 'SELECT 1' >/dev/null 2>&1 \
        || fail "MySQL localhost socket fallback does not resolve through MYSQL_UNIX_PORT=$MYSQL_SOCKET"

    log "Verified passwordless MySQL auth_socket access for OS user '$database_user'"
    log "Pinned AzerothCore localhost socket fallback to $MYSQL_SOCKET via MYSQL_UNIX_PORT"
}

read_state_value() {
    local state_file="$1"
    [[ -f "$state_file" ]] && cat "$state_file" || true
}

prepare_core_repository() {
    local old_repository
    old_repository="$(read_state_value "$STATE_DIR/core-repository")"
    if [[ -n "$old_repository" && "$old_repository" != "$CORE_REPOSITORY" ]]; then
        log "Core repository changed; removing the old source and build trees"
        rm -rf "$SOURCE_DIR" "$BUILD_DIR"
    fi

    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        rm -rf "$SOURCE_DIR"
        mkdir -p "$SOURCE_DIR"
        git -C "$SOURCE_DIR" init -q
        git -C "$SOURCE_DIR" remote add origin "$CORE_REPOSITORY"
    else
        git -C "$SOURCE_DIR" remote set-url origin "$CORE_REPOSITORY"
    fi

    log "Fetching core ref '$CORE_REF' from $CORE_REPOSITORY"
    if ! git -C "$SOURCE_DIR" fetch --force --prune --depth=1 origin "$CORE_REF"; then
        log "Shallow ref fetch failed; retrying with repository tags/history"
        git -C "$SOURCE_DIR" fetch --force --prune --tags origin
        git -C "$SOURCE_DIR" fetch --force origin "$CORE_REF"
    fi
    git -C "$SOURCE_DIR" checkout --force --detach FETCH_HEAD
    git -C "$SOURCE_DIR" submodule update --init --recursive --depth=1 \
        || git -C "$SOURCE_DIR" submodule update --init --recursive

    printf '%s\n' "$CORE_REPOSITORY" > "$STATE_DIR/core-repository"
    printf '%s\n' "$CORE_REF" > "$STATE_DIR/core-ref"
}

checkout_module_repository() {
    local repository="$1" ref="$2" directory="$3" module_name="$4"
    validate_repository_url "$repository"
    [[ "$ref" != -* ]] || fail "Git refs may not begin with a dash: $ref"

    if [[ ! -d "$directory/.git" ]]; then
        rm -rf "$directory"
        mkdir -p "$directory"
        git -C "$directory" init -q
        git -C "$directory" remote add origin "$repository"
    else
        git -C "$directory" remote set-url origin "$repository"
    fi

    log "Fetching module '$module_name' ref '$ref'"
    if ! git -C "$directory" fetch --force --prune --depth=1 origin "$ref"; then
        git -C "$directory" fetch --force --prune --tags origin
        git -C "$directory" fetch --force origin "$ref"
    fi
    git -C "$directory" checkout --force --detach FETCH_HEAD
    git -C "$directory" clean -fdx
    git -C "$directory" submodule update --init --recursive --depth=1 \
        || git -C "$directory" submodule update --init --recursive
}

prepare_modules() {
    mkdir -p "$SOURCE_DIR/modules"
    local -a desired_module_names=()
    local -a module_records=()

    if is_true "$PLAYERBOTS_ENABLED"; then
        checkout_module_repository "$PLAYERBOTS_REPOSITORY" "$PLAYERBOTS_REF" \
            "$SOURCE_DIR/modules/mod-playerbots" "mod-playerbots"
        desired_module_names+=("mod-playerbots")
        module_records+=("mod-playerbots|$PLAYERBOTS_REPOSITORY|$PLAYERBOTS_REF")
    fi

    local modules_compact="${ADDITIONAL_MODULES//[[:space:]]/}"
    if [[ -n "$modules_compact" ]]; then
        local -a entries=()
        IFS=',' read -r -a entries <<< "$modules_compact"
        local entry slug ref module_name repository
        for entry in "${entries[@]}"; do
            [[ -n "$entry" ]] || continue
            if [[ "$entry" == *@* ]]; then
                slug="${entry%@*}"
                ref="${entry##*@}"
            else
                slug="$entry"
                ref="HEAD"
            fi
            [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
                || fail "Invalid additional module '$entry'; use owner/repository or owner/repository@ref"
            [[ -n "$ref" ]] || fail "Module '$entry' has an empty Git ref"
            module_name="${slug##*/}"
            [[ "$module_name" != "mod-playerbots" ]] \
                || fail "Do not add mod-playerbots through Additional Modules; select a Playerbots distribution instead"
            if printf '%s\n' "${desired_module_names[@]}" | grep -Fxq "$module_name"; then
                fail "More than one selected module uses directory name '$module_name'"
            fi
            repository="https://github.com/$slug.git"
            checkout_module_repository "$repository" "$ref" "$SOURCE_DIR/modules/$module_name" "$module_name"
            desired_module_names+=("$module_name")
            module_records+=("$module_name|$repository|$ref")
        done
    fi

    local managed_file="$STATE_DIR/managed-modules"
    if [[ -f "$managed_file" ]]; then
        local old_module
        while IFS= read -r old_module; do
            [[ -n "$old_module" ]] || continue
            if ! printf '%s\n' "${desired_module_names[@]}" | grep -Fxq "$old_module"; then
                log "Removing no-longer-selected managed module '$old_module'"
                rm -rf "$SOURCE_DIR/modules/$old_module"
            fi
        done < "$managed_file"
    fi

    printf '%s\n' "${desired_module_names[@]}" | sed '/^$/d' > "$managed_file"
    printf '%s\n' "${module_records[@]}" | sed '/^$/d' > "$STATE_DIR/module-records"
}

build_azerothcore() {
    local structural_key previous_structural_key jobs core_commit mysql_version mysql_client_library
    mysql_version="$(read_state_value "$STATE_DIR/mysql-version")"
    mysql_client_library="$(read_state_value "$STATE_DIR/mysql-client-library")"
    [[ -n "$mysql_client_library" && -e "$mysql_client_library" ]] \
        || mysql_client_library="$(find_mysql_client_library)"
    structural_key="$(printf '%s\n' \
        "$DISTRIBUTION" "$CORE_REPOSITORY" "$CORE_REF" "$PLAYERBOTS_ENABLED" \
        "$PLAYERBOTS_REPOSITORY" "$PLAYERBOTS_REF" "$ADDITIONAL_MODULES" \
        "$BUILD_TYPE" "$EXTRA_CMAKE_OPTIONS" "$mysql_version" "$mysql_client_library" \
        | sha256sum | awk '{print $1}')"
    previous_structural_key="$(read_state_value "$STATE_DIR/build-structure-key")"

    if is_true "$FORCE_CLEAN_BUILD" || [[ "$structural_key" != "$previous_structural_key" ]]; then
        log "Preparing a clean CMake build directory"
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"

    if (( BUILD_THREADS == 0 )); then
        jobs="$(nproc)"
        (( jobs > 4 )) && jobs=4
    else
        jobs="$BUILD_THREADS"
    fi
    (( jobs >= 1 )) || jobs=1

    export MYSQL_HOME="$MYSQL_DIR"
    export PATH="$MYSQL_DIR/bin:$PATH"
    export LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH"
    export CCACHE_DIR="$BASE_DIR/ccache"
    export CCACHE_MAXSIZE="3G"

    local -a cmake_options=(
        -G Ninja
        "-DCMAKE_INSTALL_PREFIX=$DIST_DIR"
        -DAPPS_BUILD=all
        -DTOOLS_BUILD=none
        -DSCRIPTS=static
        -DMODULES=static
        -DWITH_WARNINGS=OFF
        "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
        -DCMAKE_C_COMPILER=clang
        -DCMAKE_CXX_COMPILER=clang++
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        "-DMYSQL_ROOT_DIR=$MYSQL_DIR"
        "-DMYSQL_CONFIG=$MYSQL_DIR/bin/mysql_config"
        "-DMYSQL_CONFIG_PREFER_PATH=$MYSQL_DIR/bin"
        "-DMYSQL_INCLUDE_DIR=$MYSQL_DIR/include"
        "-DMYSQL_LIBRARY=$mysql_client_library"
        "-DMYSQL_EXECUTABLE=$MYSQL_DIR/bin/mysql"
    )
    if [[ -n "$EXTRA_CMAKE_OPTIONS" ]]; then
        local -a extra_options=()
        IFS=' ' read -r -a extra_options <<< "$EXTRA_CMAKE_OPTIONS"
        cmake_options+=("${extra_options[@]}")
    fi

    log "Configuring AzerothCore ($BUILD_TYPE)"
    log "Forcing CMake MySQL headers to $MYSQL_DIR/include"
    log "Forcing CMake MySQL client library to $mysql_client_library"
    cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" "${cmake_options[@]}"

    local cached_mysql_library cached_mysql_include
    cached_mysql_library="$(sed -n 's/^MYSQL_LIBRARY:[^=]*=//p' "$BUILD_DIR/CMakeCache.txt" | tail -n1)"
    cached_mysql_include="$(sed -n 's/^MYSQL_INCLUDE_DIR:[^=]*=//p' "$BUILD_DIR/CMakeCache.txt" | tail -n1)"
    [[ "$cached_mysql_library" == "$mysql_client_library" ]] \
        || fail "CMake selected the wrong MySQL library: '${cached_mysql_library:-unset}' (expected '$mysql_client_library')"
    [[ "$cached_mysql_include" == "$MYSQL_DIR/include" ]] \
        || fail "CMake selected the wrong MySQL headers: '${cached_mysql_include:-unset}' (expected '$MYSQL_DIR/include')"

    log "CMake MySQL selection verified before compilation"
    log "Compiling AzerothCore with $jobs parallel job(s)"
    cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" --parallel "$jobs"
    log "Installing AzerothCore into $DIST_DIR"
    cmake --install "$BUILD_DIR" --config "$BUILD_TYPE"

    [[ -x "$DIST_DIR/bin/authserver" ]] || fail "Build completed without dist/bin/authserver"
    [[ -x "$DIST_DIR/bin/worldserver" ]] || fail "Build completed without dist/bin/worldserver"

    local server_binary linked_mysql unresolved_runtime linked_crypto linked_ssl
    for server_binary in "$DIST_DIR/bin/authserver" "$DIST_DIR/bin/worldserver"; do
        unresolved_runtime="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | grep 'not found' || true)"
        [[ -z "$unresolved_runtime" ]] \
            || fail "$(basename "$server_binary") has unresolved runtime libraries: $unresolved_runtime"
        linked_mysql="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null \
            | awk '/libmysqlclient\.so/{print $3; exit}')"
        [[ -n "$linked_mysql" && "$linked_mysql" == "$MYSQL_CLIENT_RUNTIME_DIR/"* ]] \
            || fail "$(basename "$server_binary") is not resolving libmysqlclient from the isolated bundled MySQL runtime (resolved '${linked_mysql:-none}')"
        linked_crypto="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | awk '/libcrypto\.so/{print $3; exit}')"
        linked_ssl="$(env LD_LIBRARY_PATH="$ACORE_LD_LIBRARY_PATH" ldd "$server_binary" 2>/dev/null | awk '/libssl\.so/{print $3; exit}')"
        [[ -n "$linked_crypto" && "$linked_crypto" != "$MYSQL_DIR/"* ]] \
            || fail "$(basename "$server_binary") is resolving libcrypto from the bundled MySQL tree ('${linked_crypto:-none}')"
        [[ -z "$linked_ssl" || "$linked_ssl" != "$MYSQL_DIR/"* ]] \
            || fail "$(basename "$server_binary") is resolving libssl from the bundled MySQL tree ('$linked_ssl')"
    done
    log "Installed server binaries verified: bundled MySQL client + Debian OpenSSL runtime"

    mkdir -p "$DIST_DIR/etc" "$DIST_DIR/etc/modules" "$DIST_DIR/bin" "$BASE_DIR/logs"
    local config_dist config_live
    [[ -f "$DIST_DIR/etc/authserver.conf.dist" ]] \
        || fail "Expected configuration template is missing: $DIST_DIR/etc/authserver.conf.dist"
    [[ -f "$DIST_DIR/etc/worldserver.conf.dist" ]] \
        || fail "Expected configuration template is missing: $DIST_DIR/etc/worldserver.conf.dist"
    while IFS= read -r -d '' config_dist; do
        config_live="${config_dist%.dist}"
        [[ -f "$config_live" ]] || cp "$config_dist" "$config_live"
    done < <(find "$DIST_DIR/etc" -maxdepth 2 -type f -name '*.conf.dist' -print0 2>/dev/null)

    core_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    printf '%s\n' "$DISTRIBUTION" > "$STATE_DIR/distribution"
    printf '%s\n' "$core_commit" > "$STATE_DIR/core-commit"
    if is_true "$PLAYERBOTS_ENABLED"; then
        printf '%s\n' "$(git -C "$SOURCE_DIR/modules/mod-playerbots" rev-parse HEAD)" > "$STATE_DIR/playerbots-commit"
    else
        rm -f "$STATE_DIR/playerbots-commit"
    fi
    {
        printf 'Distribution: %s\n' "$DISTRIBUTION"
        printf 'Core repository: %s\n' "$CORE_REPOSITORY"
        printf 'Core ref: %s\n' "$CORE_REF"
        printf 'Core commit: %s\n' "$core_commit"
        if is_true "$PLAYERBOTS_ENABLED"; then
            printf 'Playerbots repository: %s\n' "$PLAYERBOTS_REPOSITORY"
            printf 'Playerbots ref: %s\n' "$PLAYERBOTS_REF"
            printf 'Playerbots commit: %s\n' "$(git -C "$SOURCE_DIR/modules/mod-playerbots" rev-parse HEAD)"
        fi
        if [[ -s "$STATE_DIR/module-records" ]]; then
            printf 'Managed modules:\n'
            while IFS='|' read -r module_name module_repository module_ref; do
                [[ -n "$module_name" ]] || continue
                printf '  - %s (%s @ %s, commit %s)\n' "$module_name" "$module_repository" "$module_ref" \
                    "$(git -C "$SOURCE_DIR/modules/$module_name" rev-parse HEAD)"
            done < "$STATE_DIR/module-records"
        fi
        printf 'Build type: %s\n' "$BUILD_TYPE"
        printf 'Installed UTC: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    } > "$BASE_DIR/AMP-INSTALLED-VERSION.txt"

    printf '%s\n' "$structural_key" > "$STATE_DIR/build-structure-key"
}

install_client_data() {
    if ! is_true "$INSTALL_CLIENT_DATA"; then
        log "Automatic client-data installation is disabled"
        return
    fi
    [[ -n "$CLIENT_DATA_VERSION" ]] || CLIENT_DATA_VERSION="v20.0"
    [[ "$CLIENT_DATA_VERSION" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
        || fail "Invalid Client Data Release '$CLIENT_DATA_VERSION'"

    local installed_version
    installed_version="$(read_state_value "$STATE_DIR/client-data-version")"
    if [[ "$installed_version" == "$CLIENT_DATA_VERSION" \
        && -d "$DIST_DIR/bin/dbc" && -d "$DIST_DIR/bin/maps" \
        && -d "$DIST_DIR/bin/vmaps" && -d "$DIST_DIR/bin/mmaps" ]]; then
        log "Client data $CLIENT_DATA_VERSION is already installed"
        return
    fi

    local temporary_dir archive_file extract_dir data_root asset_url asset_url_fallback data_item
    temporary_dir="$(mktemp -d "$BASE_DIR/.client-data.XXXXXX")"
    archive_file="$temporary_dir/data.zip"
    extract_dir="$temporary_dir/extracted"
    mkdir -p "$extract_dir"
    asset_url="https://github.com/wowgaming/client-data/releases/download/$CLIENT_DATA_VERSION/data.zip"
    asset_url_fallback="https://github.com/wowgaming/client-data/releases/download/$CLIENT_DATA_VERSION/Data.zip"

    log "Downloading AzerothCore client data $CLIENT_DATA_VERSION"
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$archive_file" "$asset_url"; then
        rm -f "$archive_file"
        log "The lowercase data.zip asset was not available; retrying Data.zip"
        curl -fL --retry 3 --connect-timeout 30 -o "$archive_file" "$asset_url_fallback" \
            || fail "Could not download $asset_url or $asset_url_fallback"
    fi
    unzip -q "$archive_file" -d "$extract_dir"
    data_root="$(find "$extract_dir" -type d -name dbc -printf '%h\n' | head -n1)"
    [[ -n "$data_root" && -d "$data_root/maps" && -d "$data_root/vmaps" && -d "$data_root/mmaps" ]] \
        || fail "Client-data archive did not contain dbc, maps, vmaps, and mmaps directories"

    mkdir -p "$DIST_DIR/bin"
    for data_item in dbc maps vmaps mmaps data-version; do
        if [[ -e "$data_root/$data_item" ]]; then
            rm -rf "$DIST_DIR/bin/$data_item"
            mv "$data_root/$data_item" "$DIST_DIR/bin/$data_item"
        fi
    done
    rm -rf "$DIST_DIR/bin/Cameras" "$DIST_DIR/bin/cameras"
    if [[ -d "$data_root/Cameras" ]]; then
        mv "$data_root/Cameras" "$DIST_DIR/bin/Cameras"
    elif [[ -d "$data_root/cameras" ]]; then
        mv "$data_root/cameras" "$DIST_DIR/bin/Cameras"
    fi

    printf '%s\n' "$CLIENT_DATA_VERSION" > "$STATE_DIR/client-data-version"
    rm -rf "$temporary_dir"
    log "Installed client data $CLIENT_DATA_VERSION"
}

install_mysql
ensure_mysql_libaio_compat
prepare_mysql_client_runtime
initialize_mysql_data
stop_temporary_mysql
MYSQL_STARTED_HERE="false"
MYSQL_PID=""
prepare_core_repository
prepare_modules
companion_discover_installed_services
companion_prepare_installed_services
verify_portable_mysql_toolchain
build_azerothcore
companion_configure_installed_services
unset LD_LIBRARY_PATH || true
install_client_data

# Keep the human-readable report useful to both users and the launcher even if
# an older instance is missing one of the .amp-state metadata files.
{
    mysql_report_version="$(read_state_value "$STATE_DIR/mysql-version")"
    client_report_version="$(read_state_value "$STATE_DIR/client-data-version")"
    [[ -n "$mysql_report_version" ]] && printf 'MySQL version: %s\n' "$mysql_report_version"
    [[ -n "$client_report_version" ]] && printf 'Client data: %s\n' "$client_report_version"
} >> "$BASE_DIR/AMP-INSTALLED-VERSION.txt"

log "============================================================"
log "SUCCESS - INSTALL/UPDATE FINISHED"
log "============================================================"
log "Installed version details:"
sed 's/^/[AMP\/AzerothCore installer]   /' "$BASE_DIR/AMP-INSTALLED-VERSION.txt"
log "============================================================"
log "SUCCESS - INSTALL/UPDATE COMPLETE - AzerothCore is ready to start"
log "============================================================"
