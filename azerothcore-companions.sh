#!/usr/bin/env bash
# Shared managed-companion adapters for the AzerothCore AMP installer and
# launcher. Keep this small: lifecycle policy stays in azerothcore-run.sh and
# azerothcore-watchdog.sh; this file only supplies discovery, preparation, and
# adapter definitions.
COMPANION_LIBRARY_VERSION="19"
LLM_CHATTER_SOCKET_PATCH_VERSION="1"

COMPANION_KNOWN_ADAPTERS=("llm-chatter")
COMPANION_RUNTIME_IDS=()
COMPANION_RUNTIME_PIDS=()
COMPANION_RUNTIME_TIMEOUTS=()
COMPANION_RUNTIME_PID_FILES=()
COMPANION_RUNTIME_LOGS=()
COMPANION_RUNTIME_REPORTED=()

companion_normalize_repository() {
    local repository="${1,,}"
    repository="${repository%.git}"
    repository="${repository%/}"
    printf '%s' "$repository"
}

companion_module_record_matches() {
    local records_file="$1" expected_name="$2" expected_repository="$3"
    local module_name repository _
    [[ -r "$records_file" ]] || return 1
    while IFS='|' read -r module_name repository _; do
        [[ "$module_name" == "$expected_name" ]] || continue
        [[ "$(companion_normalize_repository "$repository")" == \
            "$(companion_normalize_repository "$expected_repository")" ]] || continue
        return 0
    done < "$records_file"
    return 1
}

companion_detect_llm_chatter() {
    local records_file="$STATE_DIR/module-records"
    local module_dir="$SOURCE_DIR/modules/mod-llm-chatter" resolved_repository
    companion_module_record_matches "$records_file" "mod-llm-chatter" \
        "https://github.com/Hokken/mod-llm-chatter" || return 1
    [[ -d "$module_dir/.git" ]] || return 1
    resolved_repository="$(git -C "$module_dir" remote get-url origin 2>/dev/null || true)"
    [[ "$(companion_normalize_repository "$resolved_repository")" == \
        "https://github.com/hokken/mod-llm-chatter" ]]
}

companion_adapter_detected() {
    local service_id="$1"
    case "$service_id" in
        llm-chatter) companion_detect_llm_chatter ;;
        *) return 1 ;;
    esac
}

companion_discover_installed_services() {
    local service_id temporary_file
    mkdir -p "$STATE_DIR"
    temporary_file="$(mktemp "$STATE_DIR/companion-services.XXXXXX")"
    for service_id in "${COMPANION_KNOWN_ADAPTERS[@]}"; do
        if companion_adapter_detected "$service_id"; then
            printf '%s\n' "$service_id" >> "$temporary_file"
            log "Detected managed companion service from installed module metadata: $service_id"
        fi
    done
    mv -f "$temporary_file" "$STATE_DIR/companion-services"

    if companion_module_record_matches "$STATE_DIR/module-records" "mod-ollama-chat" \
        "https://github.com/DustinHendrickson/mod-ollama-chat" \
        && companion_detect_llm_chatter; then
        log "WARNING: mod-ollama-chat and mod-llm-chatter are both installed; their chat features may overlap. Choose one unless the overlap is intentional."
    fi
}

companion_apply_llm_chatter_socket_patch() {
    local module_dir="$SOURCE_DIR/modules/mod-llm-chatter"
    local db_file="$module_dir/tools/chatter_db.py"
    local health_file="$module_dir/tools/chatter_healthcheck.py"
    local conf_file="$module_dir/conf/mod_llm_chatter.conf.dist"
    [[ -f "$db_file" && -f "$health_file" && -f "$conf_file" ]] \
        || fail "mod-llm-chatter layout changed: expected chatter_db.py, chatter_healthcheck.py, and mod_llm_chatter.conf.dist"

    # AMP compatibility patch: current upstream exposes Host/Port only. Apply
    # exact, independently idempotent replacements so an upstream change fails
    # the Update rather than risking a partial or corrupt source modification.
    python3 - "$db_file" "$health_file" "$conf_file" <<'PY'
import pathlib
import sys

db_path, health_path, conf_path = map(pathlib.Path, sys.argv[1:])

def replace_exact(path, old, new, marker):
    data = path.read_text()
    if marker in data:
        return False
    count = data.count(old)
    if count != 1:
        raise SystemExit(
            f"AMP Unix-socket compatibility patch refused {path}: "
            f"expected one safe upstream match, found {count}"
        )
    path.write_text(data.replace(old, new, 1))
    return True

db_old = '''def get_db_connection(config: dict, database: str = None):
    """Create database connection from config."""
    return mysql.connector.connect(
        host=config.get('LLMChatter.Database.Host', 'localhost'),
        port=int(config.get('LLMChatter.Database.Port', 3306)),
        user=config.get('LLMChatter.Database.User', 'acore'),
        password=config.get(
            'LLMChatter.Database.Password', 'acore'
        ),
        database=database or config.get(
            'LLMChatter.Database.Name', 'acore_characters'
        ),
        # Buffered cursors free the server-side result at
        # execute() time, preventing "Unread result found"
        # errors on the C-extension connector (cext) when a
        # prior cursor is left unclosed. See issue #31.
        buffered=True,
    )
'''
db_new = '''def get_db_connection(config: dict, database: str = None):
    """Create database connection from config."""
    # AMP COMPAT: private Unix socket support (patch v1).
    connection_args = {
        'user': config.get('LLMChatter.Database.User', 'acore'),
        'password': config.get('LLMChatter.Database.Password', 'acore'),
        'database': database or config.get(
            'LLMChatter.Database.Name', 'acore_characters'
        ),
        # Buffered cursors free the server-side result at execute() time.
        'buffered': True,
    }
    unix_socket = config.get(
        'LLMChatter.Database.UnixSocket', ''
    ).strip()
    if unix_socket:
        connection_args['unix_socket'] = unix_socket
    else:
        connection_args['host'] = config.get(
            'LLMChatter.Database.Host', 'localhost'
        )
        connection_args['port'] = int(config.get(
            'LLMChatter.Database.Port', 3306
        ))
    return mysql.connector.connect(**connection_args)
'''

format_old = '''def format_db_target(config):
    """Human string of the MySQL target being probed."""
    host = config.get(
        '__healthcheck_db_host__'
    ) or config.get('LLMChatter.Database.Host', 'localhost')
    port = config.get(
        '__healthcheck_db_port__'
    ) or config.get('LLMChatter.Database.Port', 3306)
    user = config.get('LLMChatter.Database.User', 'acore')
    name = config.get(
        'LLMChatter.Database.Name', 'acore_characters'
    )
    return f"{user}@{host}:{port}/{name}"
'''
format_new = '''def format_db_target(config):
    """Human string of the MySQL target being probed."""
    user = config.get('LLMChatter.Database.User', 'acore')
    name = config.get(
        'LLMChatter.Database.Name', 'acore_characters'
    )
    # AMP COMPAT: private Unix socket support (patch v1).
    unix_socket = config.get(
        'LLMChatter.Database.UnixSocket', ''
    ).strip()
    if unix_socket and not config.get('__healthcheck_db_host__'):
        return f"{user}@unix:{unix_socket}/{name}"
    host = config.get(
        '__healthcheck_db_host__'
    ) or config.get('LLMChatter.Database.Host', 'localhost')
    port = config.get(
        '__healthcheck_db_port__'
    ) or config.get('LLMChatter.Database.Port', 3306)
    return f"{user}@{host}:{port}/{name}"
'''

health_old = '''def _db_connect(config):
    """Open a mysql connection mirroring get_db_connection,
    honoring optional __healthcheck_db_*__ overrides."""
    import mysql.connector
    host = config.get(
        '__healthcheck_db_host__'
    ) or config.get('LLMChatter.Database.Host', 'localhost')
    port = config.get(
        '__healthcheck_db_port__'
    ) or config.get('LLMChatter.Database.Port', 3306)
    return mysql.connector.connect(
        host=host,
        port=int(port),
        user=config.get('LLMChatter.Database.User', 'acore'),
        password=config.get(
            'LLMChatter.Database.Password', 'acore'
        ),
        database=config.get(
            'LLMChatter.Database.Name', 'acore_characters'
        ),
        # See issue #31: buffered cursors avoid cext
        # "Unread result found" errors.
        buffered=True,
    )
'''
health_new = '''def _db_connect(config):
    """Open a mysql connection mirroring get_db_connection,
    honoring optional __healthcheck_db_*__ overrides."""
    import mysql.connector
    # AMP COMPAT: private Unix socket support (patch v1).
    connection_args = {
        'user': config.get('LLMChatter.Database.User', 'acore'),
        'password': config.get('LLMChatter.Database.Password', 'acore'),
        'database': config.get(
            'LLMChatter.Database.Name', 'acore_characters'
        ),
        'buffered': True,
    }
    unix_socket = config.get(
        'LLMChatter.Database.UnixSocket', ''
    ).strip()
    if unix_socket and not config.get('__healthcheck_db_host__'):
        connection_args['unix_socket'] = unix_socket
    else:
        connection_args['host'] = config.get(
            '__healthcheck_db_host__'
        ) or config.get('LLMChatter.Database.Host', 'localhost')
        connection_args['port'] = int(config.get(
            '__healthcheck_db_port__'
        ) or config.get('LLMChatter.Database.Port', 3306))
    return mysql.connector.connect(**connection_args)
'''

conf_anchor = '''#
#   LLMChatter.Database.Host
'''
conf_insert = '''# AMP COMPAT: private Unix socket support (patch v1).
# When set, the Python bridge and its startup health check use this socket and
# ignore Host/Port. Leave empty for normal TCP-based installations.
LLMChatter.Database.UnixSocket =

#
#   LLMChatter.Database.Host
'''

replace_exact(db_path, db_old, db_new, 'AMP COMPAT: private Unix socket support (patch v1)')
replace_exact(health_path, format_old, format_new, 'AMP COMPAT: private Unix socket support (patch v1)')
# The first health replacement adds the marker; key the second idempotency check
# to its specific connection_args spelling instead of the shared marker.
health_data = health_path.read_text()
if "connection_args['unix_socket'] = unix_socket" not in health_data:
    if health_data.count(health_old) != 1:
        raise SystemExit(
            f"AMP Unix-socket compatibility patch refused {health_path}: "
            "health-check connection function changed upstream"
        )
    health_path.write_text(health_data.replace(health_old, health_new, 1))
replace_exact(conf_path, conf_anchor, conf_insert, 'AMP COMPAT: private Unix socket support (patch v1)')
PY
    log "Applied/verified AMP Unix-socket compatibility patch for mod-llm-chatter"
}

companion_llm_chatter_requirements_file() {
    local module_dir="$SOURCE_DIR/modules/mod-llm-chatter"
    if [[ -f "$module_dir/tools/requirements.txt" ]]; then
        printf '%s' "$module_dir/tools/requirements.txt"
    elif [[ -f "$module_dir/requirements.txt" ]]; then
        printf '%s' "$module_dir/requirements.txt"
    else
        return 1
    fi
}

companion_prepare_llm_chatter() {
    local module_dir="$SOURCE_DIR/modules/mod-llm-chatter"
    local service_dir="$BASE_DIR/services/llm-chatter"
    local venv_dir="$service_dir/venv"
    local requirements_file dependency_hash current_hash module_commit python_version temporary_hash
    log "Preparing companion service: llm-chatter"
    [[ -f "$module_dir/tools/llm_chatter_bridge.py" ]] \
        || fail "mod-llm-chatter no longer contains tools/llm_chatter_bridge.py"
    requirements_file="$(companion_llm_chatter_requirements_file)" \
        || fail "mod-llm-chatter does not contain a supported requirements.txt"
    companion_apply_llm_chatter_socket_patch

    command -v python3 >/dev/null 2>&1 \
        || fail "python3 is required to prepare the llm-chatter companion"
    module_commit="$(git -C "$module_dir" rev-parse HEAD)"
    python_version="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
    dependency_hash="$(
        printf '%s\n' "$module_commit" "$python_version" \
            "$LLM_CHATTER_SOCKET_PATCH_VERSION" "$(sha256sum "$requirements_file" | awk '{print $1}')" \
            | sha256sum | awk '{print $1}'
    )"
    current_hash="$(cat "$service_dir/dependencies.sha256" 2>/dev/null || true)"
    if [[ "$current_hash" == "$dependency_hash" && -x "$venv_dir/bin/python" ]] \
        && "$venv_dir/bin/python" -c 'import anthropic, openai, mysql.connector' >/dev/null 2>&1; then
        log "llm-chatter Python environment is current"
        return 0
    fi

    mkdir -p "$service_dir"
    if [[ ! -x "$venv_dir/bin/python" ]] \
        || ! "$venv_dir/bin/python" -c 'import sys; raise SystemExit(0)' >/dev/null 2>&1; then
        rm -rf "$venv_dir"
        python3 -m venv "$venv_dir" \
            || fail "Could not create llm-chatter virtual environment (is python3-venv installed?)"
    fi
    "$venv_dir/bin/python" -m pip install --disable-pip-version-check -r "$requirements_file" \
        || fail "Could not install mod-llm-chatter Python requirements into its managed virtual environment"
    "$venv_dir/bin/python" -c 'import anthropic, openai, mysql.connector' \
        || fail "llm-chatter virtual environment is incomplete after requirements installation"
    temporary_hash="$(mktemp "$service_dir/dependencies.sha256.XXXXXX")"
    printf '%s\n' "$dependency_hash" > "$temporary_hash"
    mv -f "$temporary_hash" "$service_dir/dependencies.sha256"
    log "llm-chatter Python environment prepared"
}

companion_prepare_installed_services() {
    local service_id
    [[ -r "$STATE_DIR/companion-services" ]] || return 0
    while IFS= read -r service_id; do
        [[ -n "$service_id" ]] || continue
        case "$service_id" in
            llm-chatter) companion_prepare_llm_chatter ;;
            *) fail "No preparation adapter is registered for companion service '$service_id'" ;;
        esac
    done < "$STATE_DIR/companion-services"
}

companion_set_conf_value() {
    local config_file="$1" config_key="$2" config_value="$3" temporary_file
    [[ -f "$config_file" ]] || return 1
    temporary_file="$(mktemp "${config_file}.amp.XXXXXX")"
    AMP_CONFIG_KEY="$config_key" AMP_CONFIG_LINE="$config_key = $config_value" awk '
        BEGIN { target=ENVIRON["AMP_CONFIG_KEY"]; replacement=ENVIRON["AMP_CONFIG_LINE"]; found=0 }
        {
            original=$0; candidate=$0; sub(/^[[:space:]]*/, "", candidate)
            if (candidate !~ /^[#;]/) {
                separator=index(candidate, "=")
                if (separator > 0) {
                    key=substr(candidate, 1, separator - 1); sub(/[[:space:]]+$/, "", key)
                    if (key == target) { if (!found) print replacement; found=1; next }
                }
            }
            print original
        }
        END { if (!found) print replacement }
    ' "$config_file" > "$temporary_file"
    chmod --reference="$config_file" "$temporary_file" 2>/dev/null || true
    mv -f "$temporary_file" "$config_file"
}

companion_configure_llm_chatter() {
    local config_file="$DIST_DIR/etc/modules/mod_llm_chatter.conf"
    local service_log_dir="$BASE_DIR/logs/llm-chatter"
    [[ -f "$config_file" ]] \
        || fail "mod-llm-chatter was installed but its live config is missing: $config_file"
    mkdir -p "$service_log_dir"
    companion_set_conf_value "$config_file" "LLMChatter.Database.UnixSocket" "$MYSQL_SOCKET"
    companion_set_conf_value "$config_file" "LLMChatter.Database.User" "$(id -un)"
    companion_set_conf_value "$config_file" "LLMChatter.Database.Password" ""
    companion_set_conf_value "$config_file" "LLMChatter.Database.Name" "acore_characters"
    companion_set_conf_value "$config_file" "LLMChatter.RequestLog.Path" "$service_log_dir/llm_requests.jsonl"
    companion_set_conf_value "$config_file" "LLMChatter.HealthCheck.LogPath" "$service_log_dir/healthcheck.log"
    log "Configured llm-chatter to use the private MySQL Unix socket as OS/MySQL user '$(id -un)' (auth_socket, no password)"
}

companion_configure_installed_services() {
    local service_id
    [[ -r "$STATE_DIR/companion-services" ]] || return 0
    while IFS= read -r service_id; do
        [[ -n "$service_id" ]] || continue
        case "$service_id" in
            llm-chatter) companion_configure_llm_chatter ;;
            *) fail "No configuration adapter is registered for companion service '$service_id'" ;;
        esac
    done < "$STATE_DIR/companion-services"
}

companion_definition_llm_chatter() {
    COMPANION_DEF_WORKDIR="$SOURCE_DIR/modules/mod-llm-chatter/tools"
    COMPANION_DEF_LOG="$BASE_DIR/logs/llm-chatter-bridge.log"
    COMPANION_DEF_TIMEOUT=20
    COMPANION_DEF_CONFIG="$DIST_DIR/etc/modules/mod_llm_chatter.conf"
    COMPANION_DEF_HEALTH_LOG="$BASE_DIR/logs/llm-chatter/healthcheck.log"
    COMPANION_DEF_COMMAND=(
        "$BASE_DIR/services/llm-chatter/venv/bin/python"
        "$SOURCE_DIR/modules/mod-llm-chatter/tools/llm_chatter_bridge.py"
        --config "$COMPANION_DEF_CONFIG"
    )
}

companion_load_definition() {
    local service_id="$1"
    COMPANION_DEF_WORKDIR=""
    COMPANION_DEF_LOG=""
    COMPANION_DEF_TIMEOUT=15
    COMPANION_DEF_CONFIG=""
    COMPANION_DEF_HEALTH_LOG=""
    COMPANION_DEF_COMMAND=()
    case "$service_id" in
        llm-chatter) companion_definition_llm_chatter ;;
        *) return 1 ;;
    esac
}

companion_runtime_register() {
    local service_id="$1" index
    companion_load_definition "$service_id" || {
        log "WARNING: ignoring unknown managed companion service '$service_id'"
        return 0
    }
    index="${#COMPANION_RUNTIME_IDS[@]}"
    COMPANION_RUNTIME_IDS[index]="$service_id"
    COMPANION_RUNTIME_PIDS[index]=""
    COMPANION_RUNTIME_TIMEOUTS[index]="$COMPANION_DEF_TIMEOUT"
    COMPANION_RUNTIME_PID_FILES[index]="$COMPANION_PID_DIR/$service_id.pid"
    COMPANION_RUNTIME_LOGS[index]="$COMPANION_DEF_LOG"
    COMPANION_RUNTIME_REPORTED[index]="false"
}

companion_runtime_initialize() {
    local service_id
    COMPANION_PID_DIR="$RUN_DIR/companions"
    mkdir -p "$COMPANION_PID_DIR"
    rm -f "$COMPANION_PID_DIR"/*.pid 2>/dev/null || true
    COMPANION_RUNTIME_IDS=()
    COMPANION_RUNTIME_PIDS=()
    COMPANION_RUNTIME_TIMEOUTS=()
    COMPANION_RUNTIME_PID_FILES=()
    COMPANION_RUNTIME_LOGS=()
    COMPANION_RUNTIME_REPORTED=()
    [[ -r "$STATE_DIR/companion-services" ]] || return 0
    while IFS= read -r service_id; do
        [[ -n "$service_id" ]] || continue
        companion_runtime_register "$service_id"
    done < "$STATE_DIR/companion-services"
}

companion_start_all() {
    local index service_id pid status
    if ! is_true "${AMP_ACORE_MANAGE_COMPANION_SERVICES:-1}"; then
        log "Automatic management of module companion services is disabled"
        return 0
    fi
    for index in "${!COMPANION_RUNTIME_IDS[@]}"; do
        service_id="${COMPANION_RUNTIME_IDS[index]}"
        companion_load_definition "$service_id" || continue
        if [[ ! -d "$COMPANION_DEF_WORKDIR" || ! -x "${COMPANION_DEF_COMMAND[0]}" \
            || ! -f "$COMPANION_DEF_CONFIG" ]]; then
            log "ERROR: $service_id companion is not prepared; run Update"
            log "AzerothCore will remain online, but $service_id is unavailable"
            continue
        fi
        mkdir -p "$(dirname "$COMPANION_DEF_LOG")"
        touch "$COMPANION_DEF_LOG" 2>/dev/null || true
        log "Starting companion service: $service_id"
        (
            cd "$COMPANION_DEF_WORKDIR" || exit 126
            exec env PYTHONUNBUFFERED=1 "${COMPANION_DEF_COMMAND[@]}"
        ) >> "$COMPANION_DEF_LOG" 2>&1 &
        pid=$!
        COMPANION_RUNTIME_PIDS[index]="$pid"
        write_pid_record "${COMPANION_RUNTIME_PID_FILES[index]}" "$pid"

        sleep 2
        if ! process_is_running "$pid"; then
            set +e
            wait "$pid" 2>/dev/null
            status=$?
            set -e
            COMPANION_RUNTIME_PIDS[index]=""
            COMPANION_RUNTIME_REPORTED[index]="true"
            rm -f "${COMPANION_RUNTIME_PID_FILES[index]}" 2>/dev/null || true
            log "ERROR: $service_id companion failed to start (exit status $status)"
            log "AzerothCore will remain online, but $service_id is unavailable"
            [[ -n "$COMPANION_DEF_HEALTH_LOG" ]] \
                && log "$service_id health report: $COMPANION_DEF_HEALTH_LOG"
            log "$service_id bridge log: $COMPANION_DEF_LOG"
            continue
        fi
        log "$service_id bridge started (PID $pid; log: $COMPANION_DEF_LOG)"
    done
}

companion_report_unexpected_exits() {
    local index service_id pid status
    for index in "${!COMPANION_RUNTIME_IDS[@]}"; do
        pid="${COMPANION_RUNTIME_PIDS[index]:-}"
        [[ -n "$pid" && "${COMPANION_RUNTIME_REPORTED[index]}" != "true" ]] || continue
        process_is_running "$pid" && continue
        service_id="${COMPANION_RUNTIME_IDS[index]}"
        set +e
        wait "$pid" 2>/dev/null
        status=$?
        set -e
        COMPANION_RUNTIME_PIDS[index]=""
        COMPANION_RUNTIME_REPORTED[index]="true"
        rm -f "${COMPANION_RUNTIME_PID_FILES[index]}" 2>/dev/null || true
        log "ERROR: companion service $service_id exited unexpectedly with status $status"
        log "AzerothCore remains online; $service_id will not be restarted automatically"
        if companion_load_definition "$service_id" && [[ -n "$COMPANION_DEF_HEALTH_LOG" ]]; then
            log "$service_id health report: $COMPANION_DEF_HEALTH_LOG"
        fi
        log "$service_id bridge log: ${COMPANION_RUNTIME_LOGS[index]}"
    done
}

companion_stop_one() {
    local index="$1" service_id pid timeout_count
    service_id="${COMPANION_RUNTIME_IDS[index]}"
    pid="${COMPANION_RUNTIME_PIDS[index]:-}"
    timeout_count="${COMPANION_RUNTIME_TIMEOUTS[index]:-15}"
    if [[ -z "$pid" ]]; then
        rm -f "${COMPANION_RUNTIME_PID_FILES[index]}" 2>/dev/null || true
        return 0
    fi
    log "Stopping companion service: $service_id"
    if ! process_is_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        rm -f "${COMPANION_RUNTIME_PID_FILES[index]}" 2>/dev/null || true
        COMPANION_RUNTIME_PIDS[index]=""
        log "$service_id bridge stopped"
        return 0
    fi
    kill_process_tree "$pid" TERM
    while (( timeout_count-- > 0 )); do
        if ! process_is_running "$pid"; then
            wait "$pid" 2>/dev/null || true
            rm -f "${COMPANION_RUNTIME_PID_FILES[index]}" 2>/dev/null || true
            COMPANION_RUNTIME_PIDS[index]=""
            log "$service_id bridge stopped"
            return 0
        fi
        kill_process_tree "$pid" TERM
        sleep 1
    done
    log "$service_id bridge did not stop in time; killing its remaining process tree"
    kill_process_tree "$pid" KILL
    wait "$pid" 2>/dev/null || true
    rm -f "${COMPANION_RUNTIME_PID_FILES[index]}" 2>/dev/null || true
    COMPANION_RUNTIME_PIDS[index]=""
    log "$service_id bridge stopped"
    return 0
}

companion_stop_all() {
    local index
    for (( index=${#COMPANION_RUNTIME_IDS[@]}-1; index>=0; index-- )); do
        companion_stop_one "$index" || true
    done
    [[ -n "${COMPANION_PID_DIR:-}" ]] && rmdir "$COMPANION_PID_DIR" 2>/dev/null || true
    return 0
}
