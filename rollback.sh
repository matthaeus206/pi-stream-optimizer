#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

if [[ ${1:-} == --help ]]; then printf 'Usage: sudo %s\n' "$0"; exit 0; fi
(( $# == 0 )) || die "Usage: sudo $0"
lock_state
original=$STATE_DIR/original
if [[ ! -d $original ]]; then
    printf 'No active installation backup.\n'
    exit 0
fi

for unit in pi-stream-moonlight.service pi-stream-performance.service; do
    if systemctl is-active --quiet "$unit"; then systemctl stop "$unit"; fi
done
while IFS= read -r -d '' record; do
    relative=${record#"$original"}
    path=${relative%.status}
    case $(<"$record") in
        present)
            temp=$(mktemp "${path}.XXXXXX")
            if ! (cp -aT -- "${record%.status}.file" "$temp" && mv -fT -- "$temp" "$path"); then
                rm -f -- "$temp"
                die "Failed to restore $path"
            fi
            ;;
        absent) rm -f -- "$path" ;;
        *) die "Invalid backup record: $record" ;;
    esac
done < <(find "$original" -type f -name '*.status' -print0)
systemctl daemon-reload
archive=$(mktemp -d "$STATE_DIR/rollback.XXXXXX")
mv -T -- "$original" "$archive/original"
printf 'Restored original files. Backup retained in %s. Reboot to finish rollback.\n' "$archive"
