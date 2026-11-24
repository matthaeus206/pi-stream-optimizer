#!/usr/bin/env bash

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=/var/lib/pi-stream-optimizer

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

read_config() {
    local line key value
    APPLIANCE_USER=
    SUNSHINE_HOST=
    SUNSHINE_APP=Desktop
    BITRATE_KBPS=50000
    BENCHMARK_HOST=
    BENCHMARK_SECONDS=20
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ $line == *=* ]] || die "Expected KEY=value in $1"
        key=${line%%=*}
        value=${line#*=}
        case $key in
            APPLIANCE_USER|SUNSHINE_HOST|SUNSHINE_APP|BITRATE_KBPS|BENCHMARK_HOST|BENCHMARK_SECONDS)
                printf -v "$key" '%s' "$value" ;;
            *) die "Unknown configuration key: $key" ;;
        esac
    done < "$1"
    [[ -z $APPLIANCE_USER || $APPLIANCE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] ||
        die 'Invalid APPLIANCE_USER'
    [[ -z $SUNSHINE_HOST || $SUNSHINE_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] ||
        die 'Invalid SUNSHINE_HOST'
    [[ -z $BENCHMARK_HOST || $BENCHMARK_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] ||
        die 'Invalid BENCHMARK_HOST'
    [[ $SUNSHINE_APP =~ ^[a-zA-Z0-9][a-zA-Z0-9._+()\ -]*$ ]] ||
        die 'SUNSHINE_APP must use letters, numbers, spaces or ._+()-'
    [[ $BITRATE_KBPS =~ ^[1-9][0-9]{2,5}$ ]] &&
        (( BITRATE_KBPS >= 500 && BITRATE_KBPS <= 500000 )) || die 'Invalid BITRATE_KBPS'
    [[ $BENCHMARK_SECONDS =~ ^[1-9][0-9]{0,2}$ ]] &&
        (( BENCHMARK_SECONDS <= 300 )) || die 'Invalid BENCHMARK_SECONDS'
}

lock_state() {
    (( EUID == 0 )) || die 'Run this script with sudo.'
    install -d -m 0700 "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    flock -x 9
}

backup_file() {
    local path=$1 record="$STATE_DIR/original$1" status=absent
    [[ -f $record.status ]] && return 0
    mkdir -p -- "$(dirname -- "$record")"
    if [[ -e $path || -L $path ]]; then
        [[ -f $path || -L $path ]] || die "Cannot back up non-file: $path"
        cp -aT -- "$path" "$record.file"
        status=present
    fi
    printf '%s\n' "$status" > "$record.status.tmp"
    mv -T -- "$record.status.tmp" "$record.status"
}

write_file() {
    local path=$1 mode=$2 temp
    backup_file "$path"
    temp=$(mktemp "${path}.XXXXXX")
    if ! (cat > "$temp" && chmod "$mode" "$temp" && mv -fT -- "$temp" "$path"); then
        rm -f -- "$temp"
        die "Failed to install $path"
    fi
}

write_link() {
    local path=$1 target=$2
    backup_file "$path"
    ln -sfnT -- "$target" "$path"
}
