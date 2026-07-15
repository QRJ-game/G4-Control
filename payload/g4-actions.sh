#!/bin/sh
# G4 Control privileged runtime actions v0.9.2

BASE="/mnt/userdata/g4ui"
HELPER="$BASE/g4-helper"
WIFI_OFF_PIDFILE="/tmp/g4-wifi-off.pid"
HOSTAPD_SOCKET="/etc_rw/wifi/hostapd"
PUBLIC_CHAIN="G4PUBLIC"
PUBLIC_MARKER="/tmp/g4-public.enabled"
PUBLIC_PIDFILE="/tmp/g4-public.pid"
WATCHDOG_FILE="$BASE/helper-watchdog"
WATCHDOG_RESTARTS_FILE="/tmp/g4-helper-watchdog.restarts"
WATCHDOG_LAST_FILE="/tmp/g4-helper-watchdog.last"

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

watchdog_on() {
    echo 1 > "$WATCHDOG_FILE" || {
        echo "result=error"
        echo "message=watchdog_write_failed"
        return 1
    }

    echo "result=ok"
    echo "helper_watchdog=1"
    echo "interval=60"
}

watchdog_off() {
    echo 0 > "$WATCHDOG_FILE" || {
        echo "result=error"
        echo "message=watchdog_write_failed"
        return 1
    }

    echo "result=ok"
    echo "helper_watchdog=0"
}

public_running() {
    [ -f "$PUBLIC_PIDFILE" ] || return 1
    PID="$(cat "$PUBLIC_PIDFILE" 2>/dev/null)"
    is_number "$PID" || return 1
    kill -0 "$PID" 2>/dev/null
}

wifi_state() {
    VALUE="$(hostapd_cli -p "$HOSTAPD_SOCKET" -i wlan0 status 2>/dev/null | awk -F= '$1=="state" {print $2; exit}')"
    [ -n "$VALUE" ] && echo "$VALUE" || echo "SERVICE_STOPPED"
}

public_cleanup_rules() {
    while iptables -D INPUT -i br0 -j "$PUBLIC_CHAIN" 2>/dev/null; do :; done
    iptables -F "$PUBLIC_CHAIN" 2>/dev/null
    iptables -X "$PUBLIC_CHAIN" 2>/dev/null
}

wifi_macs() {
    hostapd_cli -p "$HOSTAPD_SOCKET" -i wlan0 all_sta 2>/dev/null |
        awk 'length($0)==17 && $0 ~ /:/ {print tolower($0)}'
}

public_rebuild_rules() {
    iptables -N "$PUBLIC_CHAIN" 2>/dev/null

    if ! iptables -L INPUT -n 2>/dev/null | grep -q "$PUBLIC_CHAIN"; then
        iptables -I INPUT 1 -i br0 -j "$PUBLIC_CHAIN" 2>/dev/null
    fi

    iptables -F "$PUBLIC_CHAIN" 2>/dev/null

    for MAC in $(wifi_macs); do
        case "$MAC" in
            ??:??:??:??:??:??)
                iptables -A "$PUBLIC_CHAIN" -m mac --mac-source "$MAC" -p tcp --dport 80 -j DROP 2>/dev/null
                iptables -A "$PUBLIC_CHAIN" -m mac --mac-source "$MAC" -p tcp --dport 18081 -j DROP 2>/dev/null
                iptables -A "$PUBLIC_CHAIN" -m mac --mac-source "$MAC" -p tcp --dport 17820 -j DROP 2>/dev/null
                iptables -A "$PUBLIC_CHAIN" -m mac --mac-source "$MAC" -p tcp --dport 4719 -j DROP 2>/dev/null
                ;;
        esac
    done
}

public_watcher() {
    while [ -f "$PUBLIC_MARKER" ]; do
        public_rebuild_rules
        sleep 2
    done

    public_cleanup_rules
    rm -f "$PUBLIC_PIDFILE"
}

public_on() {
    touch "$PUBLIC_MARKER" || {
        echo "result=error"
        echo "message=marker_failed"
        return 1
    }

    if ! public_running; then
        rm -f "$PUBLIC_PIDFILE"
        "$HELPER" --public-watcher
        RC="$?"

        if [ "$RC" -ne 0 ]; then
            rm -f "$PUBLIC_MARKER"
            echo "result=error"
            echo "message=watcher_launch_failed"
            echo "rc=$RC"
            return 1
        fi

        COUNT=0
        while [ "$COUNT" -lt 5 ]; do
            public_running && break
            sleep 1
            COUNT=`expr "$COUNT" + 1`
        done

        if ! public_running; then
            rm -f "$PUBLIC_MARKER"
            echo "result=error"
            echo "message=watcher_not_running"
            return 1
        fi
    fi

    echo "result=scheduled"
    echo "delay=2"
}

public_off() {
    rm -f "$PUBLIC_MARKER"

    if public_running; then
        PID="$(cat "$PUBLIC_PIDFILE" 2>/dev/null)"
        kill "$PID" 2>/dev/null
    fi

    public_cleanup_rules
    rm -f "$PUBLIC_PIDFILE"
    echo "result=ok"
}

status() {
    echo "version=0.9.2"
    echo "wifi=$(wifi_state)"
    [ -f "$PUBLIC_MARKER" ] && echo "public=1" || echo "public=0"
    public_running && echo "public_watcher=running" || echo "public_watcher=stopped"
    watchdog_enabled && echo "helper_watchdog=1" || echo "helper_watchdog=0"
    echo "watchdog_interval=60"
    echo "watchdog_restarts=$(cat "$WATCHDOG_RESTARTS_FILE" 2>/dev/null)"
    echo "watchdog_last=$(cat "$WATCHDOG_LAST_FILE" 2>/dev/null)"

    STA_STATUS="$(cat /proc/net/wireless 2>/dev/null | awk '$1 ~ /^wlan0-vxd:/ {gsub(/\./,"",$4); print $4; exit}')"
    [ -n "$STA_STATUS" ] && echo "wisp_signal=$STA_STATUS"
}

read_first_value() {
    [ -r "$1" ] || return 0
    awk 'NR==1 {gsub(/\r/, ""); print; exit}' "$1" 2>/dev/null
}

system_metrics() {
    echo "metrics_version=1"
    date '+collected_epoch=%s' 2>/dev/null

    awk '{printf "uptime_seconds=%.0f\n", $1; exit}' /proc/uptime 2>/dev/null
    awk '{print "load1=" $1; print "load5=" $2; print "load15=" $3; exit}' /proc/loadavg 2>/dev/null
    awk '/^processor[[:space:]]*:/ {count++} END {print "cpu_cores=" (count + 0)}' /proc/cpuinfo 2>/dev/null

    CPU_PAIR="$(awk '$1=="cpu" {total=0; for(i=2;i<=NF;i++) total+=$i; idle=$5+$6; printf "%.0f %.0f", total, idle; exit}' /proc/stat 2>/dev/null)"
    set -- $CPU_PAIR
    CUR_TOTAL="$1"
    CUR_IDLE="$2"
    CPU_PREV_FILE="/tmp/g4-system-cpu.prev"
    CPU_USAGE=""

    if [ -n "$CUR_TOTAL" ] && [ -n "$CUR_IDLE" ] && [ -r "$CPU_PREV_FILE" ]; then
        set -- $(cat "$CPU_PREV_FILE" 2>/dev/null)
        PREV_TOTAL="$1"
        PREV_IDLE="$2"
        CPU_USAGE="$(awk -v ct="$CUR_TOTAL" -v ci="$CUR_IDLE" -v pt="$PREV_TOTAL" -v pi="$PREV_IDLE" 'BEGIN {dt=ct-pt; di=ci-pi; if(dt>0){v=100*(dt-di)/dt; if(v<0)v=0; if(v>100)v=100; printf "%.1f",v}}')"
    fi

    if [ -n "$CUR_TOTAL" ] && [ -n "$CUR_IDLE" ]; then
        printf '%s %s\n' "$CUR_TOTAL" "$CUR_IDLE" > "$CPU_PREV_FILE"
    fi

    echo "cpu_usage_pct=$CPU_USAGE"

    for CPU_FREQ_FILE in \
        /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq \
        /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq; do
        if [ -r "$CPU_FREQ_FILE" ]; then
            CPU_FREQ="$(read_first_value "$CPU_FREQ_FILE")"
            [ -n "$CPU_FREQ" ] && echo "cpu_freq_khz=$CPU_FREQ"
            break
        fi
    done

    awk '
        /^MemTotal:/ {total=$2}
        /^MemFree:/ {free=$2}
        /^MemAvailable:/ {available=$2}
        /^Buffers:/ {buffers=$2}
        /^Cached:/ {cached=$2}
        /^SReclaimable:/ {reclaim=$2}
        /^SwapTotal:/ {swap_total=$2}
        /^SwapFree:/ {swap_free=$2}
        END {
            if(available<=0) available=free+buffers+cached+reclaim
            used=total-available
            if(used<0) used=0
            swap_used=swap_total-swap_free
            if(swap_used<0) swap_used=0
            print "mem_total_kb=" total
            print "mem_used_kb=" used
            print "mem_available_kb=" available
            print "mem_free_kb=" free
            print "mem_buffers_kb=" buffers
            print "mem_cached_kb=" cached
            print "swap_total_kb=" swap_total
            print "swap_used_kb=" swap_used
            print "swap_free_kb=" swap_free
        }
    ' /proc/meminfo 2>/dev/null

    HELPER_METRIC_PID="$(cat /tmp/g4-helper.pid 2>/dev/null)"
    if is_number "$HELPER_METRIC_PID" && kill -0 "$HELPER_METRIC_PID" 2>/dev/null; then
        echo "helper_state=running"
        echo "helper_pid=$HELPER_METRIC_PID"
    else
        echo "helper_state=stopped"
        echo "helper_pid="
    fi

    CLEANER_METRIC_PID="$(cat /tmp/g4ui-cleaner.pid 2>/dev/null)"
    if is_number "$CLEANER_METRIC_PID" && kill -0 "$CLEANER_METRIC_PID" 2>/dev/null; then
        echo "cleaner_state=running"
        echo "cleaner_pid=$CLEANER_METRIC_PID"
    else
        echo "cleaner_state=stopped"
        echo "cleaner_pid="
    fi

    watchdog_enabled && echo "helper_watchdog=1" || echo "helper_watchdog=0"
    echo "watchdog_interval=60"
    echo "watchdog_restarts=$(cat "$WATCHDOG_RESTARTS_FILE" 2>/dev/null)"
    echo "watchdog_last=$(cat "$WATCHDOG_LAST_FILE" 2>/dev/null)"

    [ -f "$PUBLIC_MARKER" ] && echo "public_mode=1" || echo "public_mode=0"
    echo "wifi_state=$(wifi_state)"

    DF_FILE="/tmp/g4-system-df"
    df -k > "$DF_FILE" 2>/dev/null
    awk '
        FNR==NR {mount_type[$2]=$3; next}
        FNR==1 {next}
        NF>=6 {
            mount=$NF
            percent=$(NF-1)
            available=$(NF-2)
            used=$(NF-3)
            total=$(NF-4)
            source=$(NF-5)
            type=mount_type[mount]
            if(type=="") type="unknown"
            if(total ~ /^[0-9]+$/ && total>0) {
                printf "fs|%s|%s|%s|%s|%s|%s|%s\n", source, mount, type, total, used, available, percent
            }
        }
    ' /proc/mounts "$DF_FILE" 2>/dev/null
    rm -f "$DF_FILE"

    for POWER in /sys/class/power_supply/*; do
        [ -d "$POWER" ] || continue
        POWER_NAME="${POWER##*/}"
        POWER_TYPE="$(read_first_value "$POWER/type")"
        POWER_CAPACITY="$(read_first_value "$POWER/capacity")"
        POWER_STATUS="$(read_first_value "$POWER/status")"
        POWER_VOLTAGE="$(read_first_value "$POWER/voltage_now")"
        POWER_CURRENT="$(read_first_value "$POWER/current_now")"
        POWER_TEMP="$(read_first_value "$POWER/temp")"
        POWER_HEALTH="$(read_first_value "$POWER/health")"
        POWER_ONLINE="$(read_first_value "$POWER/online")"
        POWER_PRESENT="$(read_first_value "$POWER/present")"
        echo "battery|$POWER_NAME|$POWER_TYPE|$POWER_CAPACITY|$POWER_STATUS|$POWER_VOLTAGE|$POWER_CURRENT|$POWER_TEMP|$POWER_HEALTH|$POWER_ONLINE|$POWER_PRESENT"
    done

    for ZONE in /sys/class/thermal/thermal_zone*; do
        [ -d "$ZONE" ] || continue
        ZONE_NAME="$(read_first_value "$ZONE/type")"
        [ -n "$ZONE_NAME" ] || ZONE_NAME="${ZONE##*/}"
        ZONE_TEMP="$(read_first_value "$ZONE/temp")"
        case "$ZONE_TEMP" in
            ""|*[!0-9-]*) continue ;;
        esac
        echo "temp|$ZONE_NAME|$ZONE_TEMP|$ZONE/temp"
    done

    for TEMP_FILE in /sys/class/hwmon/hwmon*/temp*_input /sys/tw_info/*temp*; do
        [ -r "$TEMP_FILE" ] || continue
        TEMP_RAW="$(read_first_value "$TEMP_FILE")"
        case "$TEMP_RAW" in
            ""|*[!0-9-]*) continue ;;
        esac
        TEMP_PARENT="${TEMP_FILE%/*}"
        TEMP_PARENT_NAME="$(read_first_value "$TEMP_PARENT/name")"
        [ -n "$TEMP_PARENT_NAME" ] || TEMP_PARENT_NAME="${TEMP_PARENT##*/}"
        TEMP_LABEL="${TEMP_FILE##*/}"
        echo "temp|$TEMP_PARENT_NAME/$TEMP_LABEL|$TEMP_RAW|$TEMP_FILE"
    done
}

case "$1" in
    status)
        status
        ;;
    system_metrics)
        system_metrics
        ;;
    wifi_off)
        rm -f "$WIFI_OFF_PIDFILE"
        "$HELPER" --wifi-off-worker
        RC="$?"

        if [ "$RC" -ne 0 ]; then
            echo "result=error"
            echo "message=wifi_worker_launch_failed"
            echo "rc=$RC"
            exit 1
        fi

        echo "result=scheduled"
        echo "delay=2"
        ;;
    wifi_off_worker)
        sleep 2
        hostapd_cli -p "$HOSTAPD_SOCKET" -i wlan0 disable >/tmp/g4-wifi-off.log 2>&1
        rm -f "$WIFI_OFF_PIDFILE"
        ;;
    wifi_on)
        if [ -f "$WIFI_OFF_PIDFILE" ]; then
            PID="$(cat "$WIFI_OFF_PIDFILE" 2>/dev/null)"
            is_number "$PID" && kill "$PID" 2>/dev/null
            rm -f "$WIFI_OFF_PIDFILE"
        fi

        hostapd_cli -p "$HOSTAPD_SOCKET" -i wlan0 enable 2>&1
        ;;
    public_on)
        public_on
        ;;
    public_off)
        public_off
        ;;
    public_watch)
        public_watcher
        ;;
    public_status)
        [ -f "$PUBLIC_MARKER" ] && echo "public=1" || echo "public=0"
        public_running && echo "watcher=running" || echo "watcher=stopped"
        ;;
    watchdog_on)
        watchdog_on
        ;;
    watchdog_off)
        watchdog_off
        ;;
    *)
        echo "result=error"
        echo "message=unknown_action"
        exit 2
        ;;
esac

exit $?
