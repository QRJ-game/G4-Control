#!/bin/sh
# G4UI persistent boot/cleanup service v0.9.2
# All runtime logs are kept in /tmp to avoid flash wear.

BASE="/mnt/userdata/g4ui"
HOST="$BASE/stock-host.html"
ENABLE="/etc_rw/g4ui.enable"
TARGET="/etc_ro/web/index.html"
LOG="/tmp/g4ui-boot.log"
PIDFILE="/tmp/g4ui-cleaner.pid"
HELPER="$BASE/g4-helper"
ACTIONS="$BASE/g4-actions.sh"
HELPER_PIDFILE="/tmp/g4-helper.pid"
DEFAULT_MIN_FREE_KB=256
DEFAULT_INTERVAL=21600
WATCHDOG_INTERVAL=60
WATCHDOG_FILE="$BASE/helper-watchdog"
WATCHDOG_RESTARTS_FILE="/tmp/g4-helper-watchdog.restarts"
WATCHDOG_LAST_FILE="/tmp/g4-helper-watchdog.last"

log() {
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

available_kb() {
    df -k /mnt/userdata 2>/dev/null |
        awk 'NR==2 {print $4}'
}

is_number() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

ensure_watchdog_default() {
    [ -f "$WATCHDOG_FILE" ] || echo 1 > "$WATCHDOG_FILE"
}

watchdog_enabled() {
    ensure_watchdog_default
    VALUE="$(cat "$WATCHDOG_FILE" 2>/dev/null)"
    [ "$VALUE" != "0" ]
}

watchdog_restart_count() {
    VALUE="$(cat "$WATCHDOG_RESTARTS_FILE" 2>/dev/null)"
    is_number "$VALUE" && echo "$VALUE" || echo 0
}

record_watchdog_restart() {
    COUNT="$(watchdog_restart_count)"
    COUNT=`expr "$COUNT" + 1`
    echo "$COUNT" > "$WATCHDOG_RESTARTS_FILE"
    date '+%s' > "$WATCHDOG_LAST_FILE" 2>/dev/null
}

watchdog_check() {
    watchdog_enabled || return 0
    helper_running && return 0

    log "watchdog: helper is stopped; restart requested"

    if start_helper; then
        record_watchdog_restart
        log "watchdog: helper restart successful"
        return 0
    fi

    log "watchdog: helper restart failed"
    return 1
}

cleanup_logs() {
    MIN_FREE_KB="$DEFAULT_MIN_FREE_KB"
    INTERVAL="$DEFAULT_INTERVAL"

    if [ -f "$BASE/min-free-kb" ]; then
        VALUE="$(cat "$BASE/min-free-kb" 2>/dev/null)"
        is_number "$VALUE" && MIN_FREE_KB="$VALUE"
    fi

    FREE_KB="$(available_kb)"
    if ! is_number "$FREE_KB"; then
        log "cleanup: could not read free space"
        return 0
    fi

    if [ "$FREE_KB" -ge "$MIN_FREE_KB" ]; then
        return 0
    fi

    log "cleanup: free=${FREE_KB}KB threshold=${MIN_FREE_KB}KB"

    for DIR in \
        /mnt/userdata/log \
        /mnt/userdata/logs \
        /mnt/userdata/var/log \
        /mnt/userdata/etc_rw/log \
        /mnt/userdata/etc_rw/logs \
        /mnt/userdata/etc_rw/var/log \
        /mnt/userdata/g4ui/logs
    do
        [ -d "$DIR" ] || continue

        if command -v find >/dev/null 2>&1; then
            find "$DIR" -type f \
                \( -name '*.log' -o -name '*.old' -o -name '*.gz' \
                   -o -name '*.tmp' -o -name '*.trace' \) \
                -exec rm -f {} \; 2>/dev/null
        else
            rm -f \
                "$DIR"/*.log \
                "$DIR"/*.old \
                "$DIR"/*.gz \
                "$DIR"/*.tmp \
                "$DIR"/*.trace \
                2>/dev/null
        fi
    done

    sync
    FREE_AFTER="$(available_kb)"
    log "cleanup: free_after=${FREE_AFTER}KB"
}

valid_payload() {
    [ -s "$HOST" ] || return 1
    grep -q "g4ControlOverlay" "$HOST" 2>/dev/null || return 1
    grep -q "G4 Control" "$HOST" 2>/dev/null || return 1
    return 0
}

mounted() {
    grep -q " $TARGET " /proc/mounts 2>/dev/null
}

activate() {
    [ -f "$ENABLE" ] || {
        log "activation skipped: enable marker is absent"
        return 0
    }

    valid_payload || {
        log "activation skipped: payload validation failed"
        return 0
    }

    COUNT=0
    while [ "$COUNT" -lt 60 ]; do
        [ -e "$TARGET" ] && [ -d /mnt/userdata ] && break
        COUNT=`expr "$COUNT" + 1`
        sleep 1
    done

    [ -e "$TARGET" ] || {
        log "activation failed: target is unavailable"
        return 1
    }

    if mounted; then
        log "activation skipped: already mounted"
        return 0
    fi

    if mount -o bind "$HOST" "$TARGET" >> "$LOG" 2>&1; then
        log "activation successful"
        return 0
    fi

    log "activation failed: bind mount error"
    return 1
}

deactivate() {
    COUNT=0
    while mounted && [ "$COUNT" -lt 32 ]; do
        umount "$TARGET" >> "$LOG" 2>&1 || break
        COUNT=`expr "$COUNT" + 1`
    done

    if mounted; then
        log "deactivation incomplete"
        return 1
    fi

    log "deactivation successful"
    return 0
}

cleaner_running() {
    [ -f "$PIDFILE" ] || return 1
    PID="$(cat "$PIDFILE" 2>/dev/null)"
    is_number "$PID" || return 1
    kill -0 "$PID" 2>/dev/null
}

cleaner_loop() {
    TICK=0
    cleanup_logs

    while [ -f "$ENABLE" ]; do
        watchdog_check

        TICK=`expr "$TICK" + 1`
        if [ "$TICK" -ge 360 ]; then
            cleanup_logs
            TICK=0
        fi

        sleep "$WATCHDOG_INTERVAL"
    done

    rm -f "$PIDFILE"
}

start_cleaner() {
    cleaner_running && return 0

    rm -f "$PIDFILE"
    "$HELPER" --cleaner-daemon
    RC="$?"

    if [ "$RC" -ne 0 ]; then
        log "cleaner: daemon launch failed rc=$RC"
        return 1
    fi

    COUNT=0
    while [ "$COUNT" -lt 5 ]; do
        cleaner_running && {
            log "cleaner: started pid=$(cat "$PIDFILE" 2>/dev/null)"
            return 0
        }

        sleep 1
        COUNT=`expr "$COUNT" + 1`
    done

    log "cleaner: failed to start"
    return 1
}

stop_cleaner() {
    if cleaner_running; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        kill "$PID" 2>/dev/null
    fi

    rm -f "$PIDFILE"
}

helper_pid_alive() {
    PID="$1"
    is_number "$PID" || return 1
    kill -0 "$PID" 2>/dev/null
}

helper_listener_pid() {
    netstat -lnpt 2>/dev/null |
        awk '
            $4 ~ /:18081$/ && $6 == "LISTEN" {
                split($7, process, "/")
                if (process[1] ~ /^[0-9]+$/) {
                    print process[1]
                    exit
                }
            }
        '
}

helper_pid_from_file() {
    [ -f "$HELPER_PIDFILE" ] || return 1
    PID="$(cat "$HELPER_PIDFILE" 2>/dev/null)"
    is_number "$PID" || return 1
    echo "$PID"
}

helper_running() {
    PID="$(helper_pid_from_file 2>/dev/null)"

    if helper_pid_alive "$PID"; then
        return 0
    fi

    # Recover when the process exists but the PID file is absent/stale.
    PID="$(helper_listener_pid)"

    if helper_pid_alive "$PID"; then
        echo "$PID" > "$HELPER_PIDFILE"
        return 0
    fi

    return 1
}

add_helper_pid() {
    PID="$1"
    is_number "$PID" || return 0

    case " $HELPER_PIDS " in
        *" $PID "*)
            ;;
        *)
            HELPER_PIDS="$HELPER_PIDS $PID"
            ;;
    esac
}

collect_helper_pids() {
    HELPER_PIDS=""

    PID="$(helper_pid_from_file 2>/dev/null)"
    add_helper_pid "$PID"

    PID="$(helper_listener_pid)"
    add_helper_pid "$PID"

    if command -v pidof >/dev/null 2>&1; then
        for PID in $(pidof g4-helper 2>/dev/null); do
            add_helper_pid "$PID"
        done
    fi
}

stop_stale_helpers() {
    collect_helper_pids

    for PID in $HELPER_PIDS; do
        helper_pid_alive "$PID" && kill "$PID" 2>/dev/null
    done

    # Wait briefly for the old process and TCP listener to disappear.
    COUNT=0
    while [ "$COUNT" -lt 5 ]; do
        PID="$(helper_listener_pid)"
        [ -z "$PID" ] && break
        sleep 1
        COUNT=`expr "$COUNT" + 1`
    done

    # Force-kill only if the unique G4 helper listener is still present.
    PID="$(helper_listener_pid)"
    if helper_pid_alive "$PID"; then
        kill -9 "$PID" 2>/dev/null
        sleep 1
    fi
}

start_helper() {
    helper_running && return 0

    [ -x "$HELPER" ] || {
        log "helper: binary is missing or not executable"
        return 1
    }

    [ -x "$ACTIONS" ] || {
        log "helper: actions script is missing or not executable"
        return 1
    }

    rm -f "$HELPER_PIDFILE" /tmp/g4-helper.log
    stop_stale_helpers

    "$HELPER" --daemon
    RC="$?"

    if [ "$RC" -ne 0 ]; then
        log "helper: daemon launch failed rc=$RC"
        return 1
    fi

    COUNT=0
    while [ "$COUNT" -lt 10 ]; do
        LISTENER_PID="$(helper_listener_pid)"

        if helper_pid_alive "$LISTENER_PID"; then
            echo "$LISTENER_PID" > "$HELPER_PIDFILE"
            log "helper: daemon ready pid=$LISTENER_PID port=18081"
            return 0
        fi

        sleep 1
        COUNT=`expr "$COUNT" + 1`
    done

    log "helper: daemon failed to expose port 18081"
    rm -f "$HELPER_PIDFILE"
    return 1
}

stop_helper() {
    stop_stale_helpers
    rm -f "$HELPER_PIDFILE"

    if [ -x "$ACTIONS" ]; then
        "$ACTIONS" public_off >/dev/null 2>&1
    fi

    log "helper: stopped"
}

status() {
    echo "version=0.9.2"
    [ -f "$ENABLE" ] && echo "enabled=1" || echo "enabled=0"
    valid_payload && echo "payload=ok" || echo "payload=invalid"
    mounted && echo "mounted=1" || echo "mounted=0"
    cleaner_running && echo "cleaner=running" || echo "cleaner=stopped"
    watchdog_enabled && echo "helper_watchdog=1" || echo "helper_watchdog=0"
    echo "watchdog_interval=60"
    echo "watchdog_restarts=$(watchdog_restart_count)"
    echo "watchdog_last=$(cat "$WATCHDOG_LAST_FILE" 2>/dev/null)"
    if helper_running; then
        echo "helper=running"
        echo "helper_pid=$(cat "$HELPER_PIDFILE" 2>/dev/null)"
    else
        echo "helper=stopped"
        echo "helper_listener_pid=$(helper_listener_pid)"
    fi
    [ -x "$ACTIONS" ] && "$ACTIONS" public_status 2>/dev/null
    echo "free_kb=$(available_kb)"
}

case "$1" in
    start|"")
        ensure_watchdog_default
        cleanup_logs
        start_helper
        activate
        start_cleaner
        ;;
    stop)
        stop_cleaner
        stop_helper
        deactivate
        ;;
    cleanup)
        cleanup_logs
        ;;
    cleaner-loop)
        cleaner_loop
        ;;
    status)
        status
        ;;
    restart)
        stop_cleaner
        stop_helper
        deactivate
        cleanup_logs
        start_helper
        activate
        start_cleaner
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|cleanup|status}"
        exit 2
        ;;
esac

exit $?
