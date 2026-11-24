# Raspberry Pi Moonlight appliance

Turn a Raspberry Pi 4 Model B or Pi 5 Model B into a console-only Moonlight Qt client for a Sunshine host. The stream preset requests 3840×2160 at 60 FPS, HEVC and hardware decoding at 50 Mbps. The Pi runs at stock clocks with the performance governor.

## Before installing

- Flash Raspberry Pi OS Lite (64-bit), Bookworm or Trixie. Use Imager to provision your user, SSH keys and Wi-Fi. Keep SSH or a keyboard available. Installation requires Internet access to the Raspberry Pi OS APT repositories and `dl.cloudsmith.io`.
- Keep the default full KMS graphics driver. Connect a 4K60-capable HDMI display and cable to HDMI0. On Pi 4 the installer adds the 4K60 firmware setting. On either board verify that the display is actually using 3840×2160 at 60 Hz. Use an adequate power supply and cooling.
- Set up [Sunshine](https://docs.lizardbyte.dev/projects/sunshine/latest/) on the RTX 5080 machine with current NVIDIA drivers and NVENC HEVC enabled. The host display or virtual display and the application must support the intended resolution and refresh rate. Start with SDR. Wire the PC to a LAN port on the Archer AX21.
- Connect the Pi to the Archer AX21's 5 GHz network. The onboard radio uses Wi-Fi 5 on these boards. An MT7921AU adapter can use the router's 5 GHz Wi-Fi 6 network. Use a USB 3 port, check that the adapter binds to `mt7921u`, and confirm the intended interface is associated and used for traffic. If both radios are configured, choose the active connection or route in NetworkManager. The installer leaves SSIDs, credentials and interface preferences under your control.

## Install and pair

On the Pi, install Git if needed, then clone the repository and enter its directory.

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/matthaeus206/pi-stream-optimizer.git
cd pi-stream-optimizer
```

Copy the configuration template and run the installer.

```bash
mkdir -p ~/.config/pi-stream-optimizer
cp -n config.conf ~/.config/pi-stream-optimizer/config.conf
sudo ./install.sh "$HOME/.config/pi-stream-optimizer/config.conf"
sudo reboot
```

Set `APPLIANCE_USER` to the existing regular account that owns your Moonlight settings, or leave it empty to use the account invoking `sudo`. Configuration is literal `KEY=value` text.

The first boot launches Moonlight on tty1. Add or discover the Sunshine host, then complete PIN pairing in Sunshine's web UI. For GUI-launched streams, choose **3840×2160**, **60 FPS**, **HEVC** and **force hardware decoding** in Moonlight settings. To start a paired stream automatically at boot, set `SUNSHINE_HOST` to the PC's reserved LAN IP or hostname and `SUNSHINE_APP` to the exact app name listed in Sunshine, then rerun the installer and reboot. The CLI launcher applies the hardware HEVC 4K60 preset to that stream.

SSH stays available if it was enabled before installation. tty1 becomes the Moonlight console. Use SSH or switch to another local VT for a shell. Pair Bluetooth controllers through Raspberry Pi OS using `bluetoothctl`, then trust the paired controller for reconnects. The appliance runs as the selected user with device access through the video, render, input and audio groups. PulseAudio or an existing PipeWire PulseAudio-compatible server supplies audio. If HDMI audio is silent, select the HDMI output in `raspi-config` or your audio server's controls.

## Update and roll back

```bash
./update.sh "$HOME/.config/pi-stream-optimizer/config.conf"
sudo reboot
```

Run updates as the checkout owner with a Git upstream configured. The script fast-forward pulls the tracked branch and reapplies the installer, which also refreshes Moonlight from APT. A private configuration copy outside the checkout keeps machine-specific settings out of Git.

```bash
sudo ./rollback.sh
sudo reboot
```

The installer keeps a root-only snapshot of the original managed files and links under `/var/lib/pi-stream-optimizer`. Repeated installs reuse that snapshot. Rollback restores those originals or removes files the installer created, including the tty1 getty override and managed APT source. It restores the original Pi 4 boot file as a whole, so save any later edits to that file before rolling back. Packages and their package-manager defaults, Moonlight pairing data, saved Wi-Fi connections and Bluetooth pairings are retained. Reboot to restore runtime settings.

## Benchmark and verify

Run `iperf3 -s` on a wired LAN system. Set its hostname/IP in `BENCHMARK_HOST`, or leave that field empty to use `SUNSHINE_HOST` if the same machine runs iperf3. Run the benchmark from the Pi:

```bash
./benchmark.sh "$HOME/.config/pi-stream-optimizer/config.conf"
./benchmark.sh --stress "$HOME/.config/pi-stream-optimizer/config.conf"
```

The benchmark reports CPU governor and frequency, thermal readings, firmware throttling flags when available, Wi-Fi link and power-save state, ping latency and loss, reverse TCP throughput, and reverse UDP jitter and loss at the configured stream bitrate. The optional all-core CPU load test samples temperature under load. Run it separately from an active stream. Compare the onboard and USB radios using the same Pi placement and confirm the route with `ip route get <server-ip>`. Wireless link rate and a synthetic benchmark alone cannot establish smooth streaming.

On the Pi, check these after reboot:

```bash
systemctl status pi-stream-moonlight pi-stream-performance
sudo journalctl -b -u pi-stream-moonlight --no-pager
sudo journalctl -b --no-pager _COMM=moonlight-qt
iw dev
iw dev wlan0 get power_save # Substitute your connected interface
vcgencmd get_throttled
```

If Moonlight reports `Cannot create window: no screens available`, turn on the HDMI display, select the Pi's input and check what the kernel detects:

```bash
for connector in /sys/class/drm/card*-HDMI-A-*; do
    [ -r "$connector/status" ] || continue
    printf '%s: ' "${connector##*/}"
    cat "$connector/status"
    head -n 3 "$connector/modes"
done
```

The launcher waits for an HDMI connector to report `connected` with an advertised mode, then directs Qt to that connector's DRM card. If no connector shows up, check that full KMS is enabled. If the connector stays `disconnected` or has no modes, try HDMI0, a different cable, or a different display input. After connecting the display, run `sudo systemctl reset-failed pi-stream-moonlight && sudo systemctl restart pi-stream-moonlight`.

During an actual stream, verify the negotiated codec, resolution and FPS in Moonlight's performance overlay or logs and confirm hardware decode in the logs. Check for frame loss, throttling, SSH access and controller reconnects. Lower the bitrate if Wi-Fi cannot sustain it with headroom. On Pi 4, the current [upstream Pi guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Installing-Moonlight-Qt-on-Raspberry-Pi-4) also lists a GPU memory workaround for decoder errors at 4K60. Evaluate that on the affected OS and kernel before changing firmware memory settings.

## Upstream and validation limits

The [Moonlight Qt Pi installation guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Installing-Moonlight-Qt-on-Raspberry-Pi-4) specifies Raspberry Pi OS 12 or later, the Cloudsmith APT repository and direct console launch. The installer configures that repository with a dedicated APT signing key and retains an existing equivalent source. Stream options follow the [upstream CLI source](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/cli/commandlineparser.cpp).

Development checks run on x86_64. Cloudsmith access returned HTTP 403 there. Installation on ARM64, HDMI and HEVC decoding, sustained 4K60 over Wi-Fi, temperature under load and physical controller support require verification on the target hardware.
