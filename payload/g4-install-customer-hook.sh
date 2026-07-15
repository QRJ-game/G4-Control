#!/bin/sh
# G4 Control customer-hook installer v0.9.2
#
# The factory /etc/rc already contains:
#   if [ -f /etc/custom/customer.sh ]; then
#       chmod +x /etc/custom/customer.sh
#       /etc/custom/customer.sh
#   fi
#
# Therefore no modification of /etc/rc is required.

RC="/etc/rc"
CUSTOM_DIR="/etc/custom"
TARGET="$CUSTOM_DIR/customer.sh"
HOOK="${1:-/tmp/g4-customer-hook.block}"
BASE="/mnt/userdata/g4ui"
BACKUP="$BASE/backup/customer.sh.original"
ABSENT_MARKER="$BASE/backup/customer.sh.was-absent"
META="$BASE/install.meta"
CANDIDATE="/tmp/g4-customer.candidate.$$"
ERROR_FILE="/tmp/g4-customer.error.$$"
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
    rm -f "$CANDIDATE" "$ERROR_FILE"

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

[ -r "$RC" ] || fail "factory_rc_missing"
[ -s "$HOOK" ] || fail "hook_block_missing"

if ! grep -q '/etc/custom/customer\.sh' "$RC" 2>/dev/null; then
    fail "factory_customer_hook_not_referenced"
fi

FREE_KB="$(df -k / 2>/dev/null | awk 'NR == 2 { print $4 }')"
case "$FREE_KB" in
    ""|*[!0-9]*) fail "root_free_space_unknown" ;;
esac

if [ "$FREE_KB" -lt 64 ]; then
    fail "root_free_space_too_low_${FREE_KB}KB"
fi

mkdir -p "$BASE/backup" || fail "backup_directory_failed"

ORIGINAL="absent"

if [ -f "$TARGET" ]; then
    ORIGINAL="present"

    if ! /bin/sh -n "$TARGET" 2>"$ERROR_FILE"; then
        cat "$ERROR_FILE"
        fail "existing_customer_script_invalid"
    fi

    if [ ! -s "$BACKUP" ]; then
        cat "$TARGET" > "$BACKUP" || fail "customer_backup_failed"
        chmod 600 "$BACKUP" 2>/dev/null
    fi

    rm -f "$ABSENT_MARKER"
else
    : > "$ABSENT_MARKER" || fail "absent_marker_failed"
fi

if ! remount_rw; then
    fail "root_remount_rw_failed"
fi
ROOT_CHANGED=1

mkdir -p "$CUSTOM_DIR" || fail "custom_directory_create_failed"

if [ -f "$TARGET" ] && grep -q '# BEGIN G4UI' "$TARGET" 2>/dev/null; then
    echo "G4_ALREADY"
else
    if [ -f "$TARGET" ]; then
        awk -v hook="$HOOK" '
        function emit_hook( line ) {
            while ((getline line < hook) > 0) {
                print line
            }
            close(hook)
        }
        {
            lines[NR] = $0
            if ($0 ~ /[^[:space:]]/) {
                last = NR
            }
        }
        END {
            final = lines[last]
            gsub(/^[[:space:]]+/, "", final)
            gsub(/[[:space:]]+$/, "", final)

            insert_before_exit = (final == "exit 0" || final == "exit $?")

            for (i = 1; i <= NR; i++) {
                if (i == last && insert_before_exit) {
                    print ""
                    emit_hook()
                    print ""
                }
                print lines[i]
            }

            if (!insert_before_exit) {
                print ""
                emit_hook()
            }
        }
        ' "$TARGET" > "$CANDIDATE" ||
            fail "customer_candidate_build_failed"
    else
        {
            echo '#!/bin/sh'
            echo ''
            cat "$HOOK"
            echo ''
            echo 'exit 0'
        } > "$CANDIDATE" ||
            fail "customer_candidate_create_failed"
    fi

    if ! /bin/sh -n "$CANDIDATE" 2>"$ERROR_FILE"; then
        cat "$ERROR_FILE"
        fail "customer_candidate_syntax_invalid"
    fi

    if ! grep -q '# BEGIN G4UI' "$CANDIDATE"; then
        fail "customer_candidate_marker_missing"
    fi

    if ! cat "$CANDIDATE" > "$TARGET"; then
        fail "customer_target_write_failed"
    fi

    chmod 755 "$TARGET" || fail "customer_chmod_failed"

    if ! /bin/sh -n "$TARGET" 2>"$ERROR_FILE"; then
        cat "$ERROR_FILE"

        if [ "$ORIGINAL" = "present" ] && [ -s "$BACKUP" ]; then
            cat "$BACKUP" > "$TARGET"
            chmod 755 "$TARGET" 2>/dev/null
        else
            rm -f "$TARGET"
        fi

        fail "written_customer_syntax_invalid"
    fi

    if ! grep -q '# BEGIN G4UI' "$TARGET"; then
        fail "written_customer_marker_missing"
    fi

    echo "G4_OK"
fi

sync

if ! remount_ro; then
    fail "root_remount_ro_failed"
fi
ROOT_CHANGED=0

{
    echo "VERSION=0.9.2"
    echo "MODE=customer-hook"
    echo "HOOK=$TARGET"
    echo "RC=$RC"
    echo "ORIGINAL=$ORIGINAL"
    echo "BACKUP=$BACKUP"
} > "$META" || fail "metadata_write_failed"

echo "G4_ROOT_OPTIONS=$(root_options)"
echo "G4_ORIGINAL=$ORIGINAL"
exit 0
