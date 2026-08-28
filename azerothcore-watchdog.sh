#!/usr/bin/env bash
WATCHDOG_TEMPLATE_VERSION="19"
set -u
IFS=$'\n\t'
umask 027

BASE_DIR=""
LIFECYCLE_ID=""
SUPERVISOR_PID=""
SUPERVISOR_STARTTIME=""
WORLD_PID=""
WORLD_STARTTIME=""

log() {
    printf '[AMP/AzerothCore watchdog] %s\n' "$*"
}

while (($#)); do
    case "$1" in
        --base-dir) BASE_DIR="${2:-}"; shift 2 ;;
        --lifecycle-id) LIFECYCLE_ID="${2:-}"; shift 2 ;;
        --supervisor-pid) SUPERVISOR_PID="${2:-}"; shift 2 ;;
        --supervisor-starttime) SUPERVISOR_STARTTIME="${2:-}"; shift 2 ;;
        --world-pid) WORLD_PID="${2:-}"; shift 2 ;;
        --world-starttime) WORLD_STARTTIME="${2:-}"; shift 2 ;;
        *) log "Ignoring unknown internal argument: $1"; shift ;;
    esac
done

[[ -n "$BASE_DIR" && -n "$LIFECYCLE_ID" ]] || exit 2
BASE_DIR="$(cd "$BASE_DIR" 2>/dev/null && pwd -P)" || exit 2

RUN_DIR="$BASE_DIR/run"
MYSQL_DIR="$BASE_DIR/mysql"
MYSQL_COMPAT_DIR="$MYSQL_DIR/compat"
MYSQL_RUN_DIR="$RUN_DIR/mysqld"
MYSQL_SOCKET="$MYSQL_RUN_DIR/mysqld.sock"
MYSQL_PID_FILE="$MYSQL_RUN_DIR/mysqld.pid"
MYSQL_SERVICE_PID_FILE="$RUN_DIR/mysql-service.pid"
AUTH_PID_FILE="$RUN_DIR/authserver.pid"
WORLD_PID_FILE="$RUN_DIR/worldserver.pid"
READY_PID_FILE="$RUN_DIR/readiness-monitor.pid"
METRICS_PID_FILE="$RUN_DIR/metrics-monitor.pid"
COMPANION_PID_DIR="$RUN_DIR/companions"
WATCHDOG_PID_FILE="$RUN_DIR/shutdown-watchdog.pid"
LIFECYCLE_FILE="$RUN_DIR/lifecycle.id"
CLEANUP_LOCK_FILE="$RUN_DIR/cleanup.lock"
CLEANUP_COMPLETE_MARKER="$RUN_DIR/cleanup.complete"
MYSQL_LD_LIBRARY_PATH="$MYSQL_COMPAT_DIR:$MYSQL_DIR/lib:$MYSQL_DIR/lib/private"
MYSQL_ADMIN_USER="$(id -un)"

mkdir -p "$RUN_DIR" "$MYSQL_RUN_DIR" 2>/dev/null || true

pid_starttime() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -r "/proc/$pid/stat" ]]; then
        awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
    else
        # Portable test fallback; AMP's Debian runtime always uses /proc.
        ps -o lstart= -p "$pid" 2>/dev/null | tr -d '[:space:]'
    fi
}

pid_matches() {
    local pid="$1" expected_start="${2:-}" actual_start state
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [[ -r "/proc/$pid/stat" ]]; then
        state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
    else
        state="$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print substr($1,1,1)}')"
    fi
    [[ "$state" != "Z" && -n "$state" ]] || return 1
    if [[ -n "$expected_start" ]]; then
        actual_start="$(pid_starttime "$pid" 2>/dev/null || true)"
        [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]] || return 1
    fi
    return 0
}

read_pid_record() {
    local file="$1"
    RECORD_PID=""
    RECORD_STARTTIME=""
    [[ -r "$file" ]] || return 1
    IFS=$'\t ' read -r RECORD_PID RECORD_STARTTIME _ < "$file" || true
    [[ "$RECORD_PID" =~ ^[0-9]+$ ]] || return 1
    return 0
}

wait_for_pid_exit() {
    local pid="$1" expected_start="$2" timeout_seconds="$3"
    local deadline=$((SECONDS + timeout_seconds))
    while pid_matches "$pid" "$expected_start"; do
        (( SECONDS >= deadline )) && return 1
        sleep 0.25
    done
    return 0
}

child_pids() {
    local parent_pid="$1"
    ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent_pid" '$2 == parent { print $1 }'
}

TREE_PIDS=()
TREE_STARTS=()

snapshot_process_tree() {
    local pid="$1" expected_start="${2:-}" child child_start actual_start
    pid_matches "$pid" "$expected_start" || return 0
    actual_start="$(pid_starttime "$pid" 2>/dev/null || true)"
    [[ -n "$actual_start" ]] || return 0
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        child_start="$(pid_starttime "$child" 2>/dev/null || true)"
        [[ -n "$child_start" ]] || continue
        snapshot_process_tree "$child" "$child_start"
    done < <(child_pids "$pid")
    TREE_PIDS+=("$pid")
    TREE_STARTS+=("$actual_start")
}

signal_process_snapshot() {
    local signal_name="$1" index
    for index in "${!TREE_PIDS[@]}"; do
        if pid_matches "${TREE_PIDS[index]}" "${TREE_STARTS[index]}"; then
            kill -"$signal_name" "${TREE_PIDS[index]}" 2>/dev/null || true
        fi
    done
}

process_snapshot_is_running() {
    local index
    for index in "${!TREE_PIDS[@]}"; do
        pid_matches "${TREE_PIDS[index]}" "${TREE_STARTS[index]}" && return 0
    done
    return 1
}

wait_for_process_snapshot() {
    local timeout_seconds="$1" deadline
    deadline=$((SECONDS + timeout_seconds))
    while process_snapshot_is_running; do
        (( SECONDS >= deadline )) && return 1
        sleep 0.25
    done
    return 0
}

stop_recorded_process_tree() {
    local file="$1" name="$2" term_timeout="${3:-15}" pid start
    read_pid_record "$file" || { rm -f "$file" 2>/dev/null || true; return 0; }
    pid="$RECORD_PID"
    start="$RECORD_STARTTIME"
    if ! pid_matches "$pid" "$start"; then
        rm -f "$file" 2>/dev/null || true
        return 0
    fi

    TREE_PIDS=()
    TREE_STARTS=()
    snapshot_process_tree "$pid" "$start"
    log "Stopping $name"
    signal_process_snapshot TERM
    if ! wait_for_process_snapshot "$term_timeout"; then
        log "$name did not stop after ${term_timeout}s; sending SIGKILL to its remaining process tree"
        signal_process_snapshot KILL
        wait_for_process_snapshot 5 || true
    fi
    rm -f "$file" 2>/dev/null || true
    log "$name stopped"
    return 0
}

stop_companion_services() {
    local file service_id
    [[ -d "$COMPANION_PID_DIR" ]] || return 0
    for file in "$COMPANION_PID_DIR"/*.pid; do
        [[ -e "$file" ]] || continue
        service_id="$(basename "$file" .pid)"
        stop_recorded_process_tree "$file" "companion service: $service_id" 20 || true
    done
    rmdir "$COMPANION_PID_DIR" 2>/dev/null || true
    return 0
}

mysql_process_record() {
    if read_pid_record "$MYSQL_SERVICE_PID_FILE" && pid_matches "$RECORD_PID" "$RECORD_STARTTIME"; then
        return 0
    fi

    local pid=""
    if [[ -r "$MYSQL_PID_FILE" ]]; then
        pid="$(tr -dc '0-9' < "$MYSQL_PID_FILE" 2>/dev/null || true)"
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    pid_matches "$pid" "" || return 1
    RECORD_PID="$pid"
    RECORD_STARTTIME="$(pid_starttime "$pid" 2>/dev/null || true)"
    return 0
}

stop_mysql() {
    local pid start
    mysql_process_record || {
        rm -f "$MYSQL_SERVICE_PID_FILE" "$MYSQL_PID_FILE" "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" 2>/dev/null || true
        return 0
    }
    pid="$RECORD_PID"
    start="$RECORD_STARTTIME"

    log "Stopping MySQL gracefully"
    if [[ -x "$MYSQL_DIR/bin/mysqladmin" && -S "$MYSQL_SOCKET" ]]; then
        timeout --signal=TERM --kill-after=3s 30s \
            env LD_LIBRARY_PATH="$MYSQL_LD_LIBRARY_PATH" \
            "$MYSQL_DIR/bin/mysqladmin" --no-defaults --protocol=socket \
            --socket="$MYSQL_SOCKET" --user="$MYSQL_ADMIN_USER" shutdown \
            >/dev/null 2>&1 || true
    fi

    if pid_matches "$pid" "$start" && ! wait_for_pid_exit "$pid" "$start" 10; then
        log "MySQL did not finish its graceful shutdown; sending SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        wait_for_pid_exit "$pid" "$start" 10 || true
    fi
    if pid_matches "$pid" "$start"; then
        log "MySQL is still running; sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        wait_for_pid_exit "$pid" "$start" 5 || true
    fi

    rm -f "$MYSQL_SERVICE_PID_FILE" "$MYSQL_PID_FILE" "$MYSQL_SOCKET" "$MYSQL_SOCKET.lock" 2>/dev/null || true
    log "MySQL stopped"
}

current_lifecycle_matches() {
    [[ -r "$LIFECYCLE_FILE" ]] || return 1
    [[ "$(cat "$LIFECYCLE_FILE" 2>/dev/null || true)" == "$LIFECYCLE_ID" ]]
}

cleanup_already_complete() {
    [[ -r "$CLEANUP_COMPLETE_MARKER" ]] || return 1
    [[ "$(cat "$CLEANUP_COMPLETE_MARKER" 2>/dev/null || true)" == "$LIFECYCLE_ID" ]]
}

watchdog_exit() {
    if [[ -r "$WATCHDOG_PID_FILE" ]]; then
        local recorded_pid=""
        read -r recorded_pid _ < "$WATCHDOG_PID_FILE" 2>/dev/null || true
        if [[ "$recorded_pid" == "$$" ]]; then
            rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true
        fi
    fi
}
trap watchdog_exit EXIT

printf '%s\t%s\t%s\n' "$$" "$(pid_starttime $$ 2>/dev/null || true)" "$LIFECYCLE_ID" > "$WATCHDOG_PID_FILE"

# The watchdog is deliberately detached from the launcher process tree. It is a
# last-resort lifecycle owner if AMP force-kills the Bash supervisor before its
# EXIT trap can finish.
while current_lifecycle_matches; do
    cleanup_already_complete && exit 0
    if ! pid_matches "$SUPERVISOR_PID" "$SUPERVISOR_STARTTIME" \
        || ! pid_matches "$WORLD_PID" "$WORLD_STARTTIME"; then
        break
    fi
    sleep 0.25
done

current_lifecycle_matches || exit 0
cleanup_already_complete && exit 0

exec 9>"$CLEANUP_LOCK_FILE"
if ! flock -w 90 9; then
    log "Could not acquire the shutdown cleanup lock"
    exit 1
fi

current_lifecycle_matches || exit 0
cleanup_already_complete && exit 0

log "Managed process exited; ensuring all AzerothCore services are stopped"

# Stop helper processes first so no further readiness or metric SQL queries run.
stop_recorded_process_tree "$READY_PID_FILE" "readiness monitor" 3
stop_recorded_process_tree "$METRICS_PID_FILE" "metrics monitor" 3

# If AMP killed the launcher rather than issuing the normal console shutdown,
# worldserver may still be alive. TERM it briefly, then force it if necessary.
if read_pid_record "$WORLD_PID_FILE" && pid_matches "$RECORD_PID" "$RECORD_STARTTIME"; then
    stop_recorded_process_tree "$WORLD_PID_FILE" "worldserver" 20
else
    rm -f "$WORLD_PID_FILE" 2>/dev/null || true
fi

# Companion workers stop after worldserver, matching normal launcher cleanup.
# Each PID file carries the lifecycle/start-time identity recorded by the
# launcher, and the process-tree snapshot prevents reparented helper children
# from retaining AMP file descriptors.
stop_companion_services

# authserver must stop before MySQL, otherwise it logs lost-connection errors.
stop_recorded_process_tree "$AUTH_PID_FILE" "authserver" 20
stop_mysql

rm -f "$RUN_DIR/worldserver.ready" 2>/dev/null || true
printf '%s\n' "$LIFECYCLE_ID" > "$CLEANUP_COMPLETE_MARKER"
log "Shutdown cleanup complete"
