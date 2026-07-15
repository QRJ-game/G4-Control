#!/bin/sh
# G4 Control startup patcher v0.4.4
# Preserves the original startup script bytes and patches entirely on-device.

TARGET="${1:-/etc/rc}"
HOOK="${2:-/tmp/g4-startup-hook.block}"
BACKUP="${3:-/mnt/userdata/g4ui/backup/etc-rc.original}"

PID="$$"
CANDIDATE="/tmp/g4-startup.candidate.$PID"
ERROR_FILE="/tmp/g4-startup.error.$PID"

cleanup() {
    rm -f "$CANDIDATE" "$ERROR_FILE"
}

fail() {
    echo "G4_ERROR:$1"
    cleanup
    exit 1
}

restore_backup() {
    if [ -s "$BACKUP" ]; then
        cat "$BACKUP" > "$TARGET" 2>/dev/null
        chmod 755 "$TARGET" 2>/dev/null
    fi
}

trap cleanup EXIT INT TERM

[ -f "$TARGET" ] || fail "target_missing"
[ -r "$TARGET" ] || fail "target_not_readable"
[ -w "$TARGET" ] || fail "target_not_writable"
[ -s "$HOOK" ] || fail "hook_missing"

if ! /bin/sh -n "$TARGET" 2>"$ERROR_FILE"; then
    cat "$ERROR_FILE"
    fail "original_syntax_invalid"
fi

if grep -q '# BEGIN G4UI' "$TARGET" 2>/dev/null; then
    echo "G4_ALREADY"
    exit 0
fi

mkdir -p "$(dirname "$BACKUP")" || fail "backup_directory_failed"

if [ ! -s "$BACKUP" ]; then
    cat "$TARGET" > "$BACKUP" || fail "backup_failed"
    chmod 600 "$BACKUP" 2>/dev/null
fi

# Build the candidate on the router. Insert before a final plain exit command
# only when that exit is the final nonblank line; otherwise append the hook.
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
' "$TARGET" > "$CANDIDATE" || fail "candidate_build_failed"

if ! /bin/sh -n "$CANDIDATE" 2>"$ERROR_FILE"; then
    cat "$ERROR_FILE"
    fail "candidate_syntax_invalid"
fi

if ! grep -q '# BEGIN G4UI' "$CANDIDATE"; then
    fail "candidate_marker_missing"
fi

# Overwrite the existing inode. This does not require creating a file in /etc.
if ! cat "$CANDIDATE" > "$TARGET"; then
    restore_backup
    fail "target_write_failed"
fi

chmod 755 "$TARGET" 2>/dev/null

if ! /bin/sh -n "$TARGET" 2>"$ERROR_FILE"; then
    cat "$ERROR_FILE"
    restore_backup
    fail "written_syntax_invalid"
fi

if ! grep -q '# BEGIN G4UI' "$TARGET"; then
    restore_backup
    fail "written_marker_missing"
fi

sync
echo "G4_OK"
exit 0
