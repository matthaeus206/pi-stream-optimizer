#!/usr/bin/env bash
set -euo pipefail

: "${RUNTIME_DIRECTORY:?Run this launcher via pi-stream-moonlight.service}"
shopt -s nullglob
for attempt in {0..15}; do
    for status_file in /sys/class/drm/card*-HDMI-A-*/status; do
        connector=${status_file%/status}
        name=${connector##*/}
        [[ $name =~ ^(card[0-9]+)-HDMI-A-[0-9]+$ ]] || continue
        device=/dev/dri/${BASH_REMATCH[1]}
        [[ -c $device ]] || continue
        if ! IFS= read -r status < "$status_file" || [[ $status != connected ]]; then
            continue
        fi
        if ! IFS= read -r mode < "$connector/modes" || [[ -z $mode ]]; then
            continue
        fi
        config=$RUNTIME_DIRECTORY/eglfs-kms.json
        printf '{"device":"%s"}\n' "$device" > "$config"
        export QT_QPA_EGLFS_KMS_CONFIG=$config
        printf 'Moonlight: using %s for %s (first advertised mode: %s).\n' "$device" "$name" "$mode"
        exec "$@"
    done
    if (( attempt < 15 )); then sleep 1; fi
done

printf 'Moonlight: no connected HDMI display with usable modes. Check the display, cable and full KMS driver.\n' >&2
for status_file in /sys/class/drm/card*-HDMI-A-*/status; do
    connector=${status_file%/status}
    status=unreadable
    IFS= read -r status < "$status_file" || status=unreadable
    printf '  %s: %s\n' "${connector##*/}" "$status" >&2
done
exit 1
