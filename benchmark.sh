#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() { printf 'Usage: %s [--stress] [config.conf]\n' "$0"; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
stress=no
if [[ ${1:-} == --stress ]]; then stress=yes; shift; fi
(( $# <= 1 )) || { usage >&2; exit 2; }
read_config "${1:-$PROJECT_DIR/config.conf}"
host=${BENCHMARK_HOST:-$SUNSHINE_HOST}
result=0
worker=
cleanup() {
    if [[ -n $worker ]]; then
        kill "$worker" 2>/dev/null || true
        wait "$worker" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot() {
    printf '\n--- %s ---\n' "$(date -Is)"
    local sensor
    for sensor in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r $sensor ]] || continue
        awk -v zone="$(<"${sensor%/temp}/type")" '{printf "%s %.1f °C\n", zone, $1/1000}' "$sensor"
    done
    if command -v vcgencmd >/dev/null; then vcgencmd get_throttled || true; fi
}

printf 'CPU governor and frequency (kHz) by policy\n'
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [[ -r $policy/scaling_governor && -r $policy/scaling_cur_freq ]] || continue
    printf '%s %s %s\n' "${policy##*/}" "$(<"$policy/scaling_governor")" "$(<"$policy/scaling_cur_freq")"
done
if command -v iw >/dev/null; then
    while read -r iface; do
        iw dev "$iface" link || true
        iw dev "$iface" get power_save || true
        if command -v ethtool >/dev/null; then
            ethtool -i "$iface" 2>/dev/null || true
        fi
    done < <(iw dev | awk '$1 == "Interface" {print $2}')
fi

snapshot
if [[ $stress == yes ]]; then
    command -v stress-ng >/dev/null || die 'Install stress-ng to run the CPU load test.'
    printf 'Sampling thermal sensors under all-core CPU load for %s seconds.\n' "$BENCHMARK_SECONDS"
    stress-ng --cpu "$(nproc)" --timeout "${BENCHMARK_SECONDS}s" --metrics-brief &
    worker=$!
    while kill -0 "$worker" 2>/dev/null; do sleep 2; snapshot; done
    wait "$worker" || result=1
    worker=
fi
if [[ -n $host ]]; then
    command -v iperf3 >/dev/null || die 'Install iperf3 to run throughput tests.'
    printf '\nLatency and loss to %s\n' "$host"
    ping -c 20 -i 0.2 -W 2 -- "$host" || result=1
    printf '\nTCP throughput from the wired host to the Pi\n'
    iperf3 -c "$host" -R -t "$BENCHMARK_SECONDS" --connect-timeout 3000 || result=1
    printf '\nUDP loss and jitter at %s Kbps from the wired host to the Pi\n' "$BITRATE_KBPS"
    iperf3 -c "$host" -R -u -b "${BITRATE_KBPS}K" -t "$BENCHMARK_SECONDS" --connect-timeout 3000 || result=1
else
    printf '\nNetwork throughput skipped. Set BENCHMARK_HOST to an iperf3 server.\n'
fi
snapshot
exit "$result"
