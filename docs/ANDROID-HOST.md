# Android phone as host — survival checklist

The host is a Samsung Galaxy Z Fold3 running Termux. Android is designed to
kill exactly this kind of workload; every item below is needed (audit §5.3).
A phone host can be *reasonably* reliable for personal use, never *highly*
reliable — hardware failure, thermal throttling and OS policy remain.

## 1. Install the apps — SAME SOURCE WARNING
Install **Termux, Termux:API and Termux:Boot all from F-Droid**. Mixing
Play Store and F-Droid builds breaks the shared UID and the add-ons stop
talking to Termux. Open Termux:Boot once after install so it registers for
the boot broadcast.

## 2. Packages
```bash
pkg update && pkg upgrade -y
pkg install -y python git tmux curl jq openssh proot-distro termux-api termux-services
pkg install -y tur-repo && pkg install -y cloudflared
termux-setup-storage
```
cloudflared MUST be the Termux package: Cloudflare's linux-arm64 binary is
glibc and will not execute under Android's bionic libc in Termux (it works
inside PRoot Ubuntu, at a performance cost).

## 3. Install this repo on the phone
```bash
git clone https://github.com/Mayank9644/cloud-portal ~/apps/cloud-portal-src
cd ~/apps/cloud-portal-src && bash scripts/install.sh   # copies to ~/apps/cloud-portal
cp scripts/local.env.example scripts/local.env          # edit: private NTFY_TOPIC
export HOST_DAEMON_TOKEN='<a long random token>'         # required for daemon actions
```

## 4. Battery / Doze exemptions (do ALL of them)
- Settings → Apps → Termux / Termux:API / Termux:Boot → Battery → **Unrestricted**
- Samsung: Settings → Battery → Background usage limits → **Never sleeping
  apps** → add all three Termux apps
- Device Care: disable "Put unused apps to sleep" for them

## 5. Phantom Process Killer (Android 12+) — via ADB from a computer, once
PRoot's child processes are reaped by this even with a wake-lock, unless:
```bash
adb shell device_config put activity_manager max_phantom_processes 2147483647
adb shell settings put global settings_enable_monitor_phantom_procs false
adb shell dumpsys deviceidle whitelist +com.termux
# then reboot the phone
```

## 6. Supervision + boot
```bash
pkg install termux-services   # then restart Termux once
bash scripts/android/install-services.sh     # runit units in $PREFIX/var/service
mkdir -p ~/.termux/boot
cp scripts/android/boot-cloudhost.sh ~/.termux/boot/10-cloudhost.sh
chmod +x ~/.termux/boot/10-cloudhost.sh
```
**Boot test:** reboot the phone, do NOT open Termux, wait 2 minutes, then
check the portal / `host.` hostname. Services must come back on their own.

## 7. Power & thermal
- Keep it plugged in; enable Samsung **Protect Battery** (caps charge at
  85%) or use a smart-plug timer — a 24/7 100% charge cooks the battery.
- Screen off, out of sunlight, nothing covering the back. The daemon flags
  battery temperature >45°C in its vitals `warning` field.
- Two PRoot distros + 2 tunnels 24/7 *will* run warm; throttling is a when,
  not an if.

## 8. Dead-man's switch
`.github/workflows/healthcheck.yml` probes the public URLs every 15
minutes and opens a GitHub issue when they are down. It can **alert** you —
it can never wake the phone. Also recommended: UptimeRobot (free) checking
the same URLs → private ntfy topic.
