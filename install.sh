#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() { printf 'Usage: sudo %s [config.conf]\n' "$0"; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
(( $# <= 1 )) || { usage >&2; exit 2; }
(( EUID == 0 )) || die 'Run this script with sudo from your regular Pi user.'
read_config "${1:-$PROJECT_DIR/config.conf}"

[[ $(dpkg --print-architecture) == arm64 && -f /etc/rpi-issue ]] ||
    die 'Raspberry Pi OS Lite 64-bit is required.'
model=$(tr -d '\000' < /proc/device-tree/model)
case $model in
    'Raspberry Pi 4 Model B'*) pi4=yes ;;
    'Raspberry Pi 5 Model B'*) pi4=no ;;
    *) die "Unsupported model: $model" ;;
esac
source /etc/os-release
case ${VERSION_CODENAME:-} in
    bookworm|trixie) ;;
    *) die 'Use Raspberry Pi OS Lite Bookworm or Trixie.' ;;
esac
[[ $(systemctl get-default) == multi-user.target ]] ||
    die 'Set Raspberry Pi OS Lite to boot to the console first.'
systemctl is-enabled --quiet NetworkManager.service ||
    die 'An enabled NetworkManager service is required.'
[[ -f /boot/firmware/config.txt && ! -L /boot/firmware/config.txt ]] ||
    die 'Expected a regular /boot/firmware/config.txt.'
[[ -n $APPLIANCE_USER ]] || APPLIANCE_USER=${SUDO_USER:-}
[[ -n $APPLIANCE_USER && $APPLIANCE_USER != root ]] ||
    die 'Set APPLIANCE_USER to an existing non-root account.'
uid=$(id -u -- "$APPLIANCE_USER")
(( uid >= 1000 && uid < 65534 )) || die 'Use a regular non-root account.'
lock_state

export DEBIAN_FRONTEND=noninteractive
repo=https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-qt
keyring=/etc/apt/keyrings/pi-stream-optimizer-moonlight.gpg
source_file=/etc/apt/sources.list.d/pi-stream-optimizer-moonlight.list
# Remove a previous managed source from this bootstrap invocation only, so its
# availability does not affect installing the prerequisites to refresh its key.
bootstrap=$(mktemp -d)
trap 'rm -rf -- "$bootstrap"' EXIT
chmod 0755 "$bootstrap"
for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f $file && $file != "$source_file" ]] || continue
    ln -s -- "$file" "$bootstrap/"
done
apt_base=(-o "Dir::Etc::sourceparts=$bootstrap")
apt-get "${apt_base[@]}" -o APT::Update::Error-Mode=any update
apt-get "${apt_base[@]}" install -y --no-remove --no-install-recommends curl ca-certificates gnupg

existing_source=
for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f $file && $file != "$source_file" ]] || continue
    if grep -Eq '^[[:space:]]*(deb[[:space:]]|URIs:).*dl\.cloudsmith\.io/public/moonlight-game-streaming/moonlight-qt/' "$file"; then
        existing_source=$file
        break
    fi
done
if [[ -n $existing_source ]]; then
    [[ ! -e $source_file ]] || die "Duplicate Moonlight repository in $existing_source and $source_file."
    printf 'Using existing Moonlight APT source %s\n' "$existing_source"
else
    curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' "$repo/gpg.key" > "$bootstrap/moonlight.key"
    gpg --batch --no-options --dearmor < "$bootstrap/moonlight.key" > "$bootstrap/moonlight.gpg"
    install -d -m 0755 /etc/apt/keyrings
    write_file "$keyring" 0644 < "$bootstrap/moonlight.gpg"
    write_file "$source_file" 0644 <<APT
deb [arch=arm64 signed-by=$keyring] $repo/deb/raspbian $VERSION_CODENAME main
APT
fi
apt-get -o APT::Update::Error-Mode=any update
firmware=firmware-mediatek
if ! apt-cache show "$firmware" >/dev/null 2>&1; then firmware=firmware-misc-nonfree; fi
audio_packages=(pulseaudio)
if dpkg-query -W -f='${db:Status-Status}' pipewire-pulse 2>/dev/null | grep -qx installed; then
    audio_packages=()
fi
apt-get install -y --no-remove --no-install-recommends moonlight-qt iw iperf3 iputils-ping \
    ethtool stress-ng bluez dbus-user-session "$firmware" "${audio_packages[@]}"
for group in video render input audio; do
    getent group "$group" >/dev/null || die "Missing device group: $group"
done
moonlight=$(command -v moonlight-qt) || die 'moonlight-qt is missing after installation.'

install -d -m 0755 /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d
write_file /etc/NetworkManager/conf.d/90-pi-stream-optimizer.conf 0644 <<'NM'
[connection]
wifi.powersave=2
NM
# A connection can override NetworkManager's global default. Apply the setting
# on activation as well, with no changes to saved Wi-Fi credentials/profiles.
write_file /etc/NetworkManager/dispatcher.d/90-pi-stream-optimizer 0755 <<'DISPATCHER'
#!/bin/sh
case "${2:-}" in
    up|reapply|dhcp4-change|dhcp6-change)
        [ -d "/sys/class/net/$1/wireless" ] || [ -e "/sys/class/net/$1/phy80211" ] || exit 0
        exec /usr/sbin/iw dev "$1" set power_save off
        ;;
esac
DISPATCHER

if [[ $pi4 == yes ]]; then
    awk '
        $0 == "# BEGIN pi-stream-optimizer" { managed=1; next }
        $0 == "# END pi-stream-optimizer" { managed=0; next }
        !managed { print }
        END {
            if (managed) exit 1
            print "# BEGIN pi-stream-optimizer\n[pi4]\nhdmi_enable_4kp60=1\n[all]\n# END pi-stream-optimizer"
        }
    ' /boot/firmware/config.txt > "$bootstrap/config.txt"
    write_file /boot/firmware/config.txt "$(stat -c '%a' /boot/firmware/config.txt)" < "$bootstrap/config.txt"
fi

unit_dir=/etc/systemd/system
wants_dir=$unit_dir/multi-user.target.wants
install -d -m 0755 "$wants_dir"
write_file "$unit_dir/pi-stream-performance.service" 0644 <<'UNIT'
[Unit]
Description=Select the performance CPU governor
Before=pi-stream-moonlight.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -ec 'found=0; for policy in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -w "$$policy" ] || continue; echo performance > "$$policy"; found=1; done; test "$$found" -eq 1'

[Install]
WantedBy=multi-user.target
UNIT

launcher=/usr/local/libexec/pi-stream-moonlight-launch
install -d -m 0755 /usr/local/libexec
write_file "$launcher" 0755 < "$PROJECT_DIR/moonlight-launch.sh"
launch="$launcher $moonlight"
if [[ -n $SUNSHINE_HOST ]]; then
    launch+=" stream --resolution 3840x2160 --fps 60 --bitrate $BITRATE_KBPS"
    launch+=" --video-codec HEVC --video-decoder hardware -- \"$SUNSHINE_HOST\" \"$SUNSHINE_APP\""
fi

write_file "$unit_dir/pi-stream-moonlight.service" 0644 <<UNIT
[Unit]
Description=Moonlight game streaming on the local console
Wants=network-online.target bluetooth.service
After=network-online.target bluetooth.service systemd-user-sessions.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=$APPLIANCE_USER
SupplementaryGroups=video render input audio
PAMName=login
RuntimeDirectory=pi-stream-moonlight
RuntimeDirectoryMode=0700
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment=SDL_AUDIODRIVER=pulseaudio
ExecStart=$launch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemd-analyze verify "$unit_dir/pi-stream-performance.service" "$unit_dir/pi-stream-moonlight.service"
write_link "$unit_dir/getty@tty1.service" /dev/null
write_link "$wants_dir/pi-stream-performance.service" ../pi-stream-performance.service
write_link "$wants_dir/pi-stream-moonlight.service" ../pi-stream-moonlight.service
systemctl daemon-reload
printf 'Installed. Reboot to apply the boot, console, Wi-Fi and governor settings.\n'
