#!/bin/sh
# G4 Control customer-hook rollback v0.9.2

TARGET="/etc/custom/customer.sh"
BASE="/mnt/userdata/g4ui"
BACKUP="$BASE/backup/customer.sh.original"
ABSENT_MARKER="$BASE/backup/customer.sh.was-absent"
META="$BASE/install.meta"
ROOT_CHANGED=0

root_options() {
    awk '$1 == "/dev/root" && $2 == "/" { print $4; exit }' /proc/mounts
}

root_is_rw() {
    OPTS="$(root_options)"
    case ",$OPTS," in
        *,rw,*) return 0 ;;
        *) return 1 ;;
    esac
}

remount_rw() {
    root_is_rw && return 0

    mount -o remount,rw / 2>/dev/null ||
        mount -o remount,rw /dev/root / 2>/dev/null ||
        return 1

    root_is_rw
}

remount_ro() {
    root_is_rw || return 0

    mount -o remount,ro / 2>/dev/null ||
        mount -o remount,ro /dev/root / 2>/dev/null ||
        return 1

    ! root_is_rw
}

cleanup() {
    if [ "$ROOT_CHANGED" = "1" ]; then
        remount_ro >/dev/null 2>&1
    fi
}

fail() {
    echo "G4_ERROR:$1"
    cleanup
    exit 1
}

trap cleanup EXIT INT TERM

if ! remount_rw; then
    fail "root_remount_rw_failed"
fi
ROOT_CHANGED=1

if [ -s "$BACKUP" ]; then
    cat "$BACKUP" > "$TARGET" ||
        fail "customer_restore_failed"
    chmod 755 "$TARGET" 2>/dev/null

    if ! /bin/sh -n "$TARGET" 2>/dev/null; then
        fail "restored_customer_invalid"
    fi

    echo "G4_RESTORED"
elif [ -f "$ABSENT_MARKER" ]; then
    if [ -f "$TARGET" ] &&
       grep -q '# BEGIN G4UI' "$TARGET" 2>/dev/null; then
        rm -f "$TARGET" ||
            fail "customer_remove_failed"
    fi

    rmdir /etc/custom 2>/dev/null
    echo "G4_REMOVED"
else
    fail "rollback_state_unknown"
fi

sync

if ! remount_ro; then
    fail "root_remount_ro_failed"
fi
ROOT_CHANGED=0

rm -f "$META"
echo "G4_ROOT_OPTIONS=$(root_options)"
exit 0
