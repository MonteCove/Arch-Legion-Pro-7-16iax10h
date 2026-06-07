#!/usr/bin/env bash
# camera-privacy-guard.sh — make the Lenovo camera privacy switch ACTUALLY block the
# camera. On this Legion the switch sets V4L2 privacy=1 but uvcvideo keeps streaming
# (privacy theater). This watcher polls the privacy bit and unbinds the uvcvideo USB
# interface when privacy is ON (so /dev/video0+1 vanish and capture gets ENODEV),
# rebinding when OFF. Match by VID:PID so it's port-independent.
#
# Verified on-device: camera 30c9:00f8 at 3-11; BOTH video nodes live on iface :1.0.
set -uo pipefail
VID=30c9
PID=00f8
DRV=/sys/bus/usb/drivers/uvcvideo
POLL="${CAM_GUARD_POLL:-1}"

find_devdir() {                       # echo the USB device dir basename (e.g. 3-11), by VID:PID
  local d
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor")" = "$VID" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ]; then
      basename "$d"; return 0
    fi
  done
  return 1
}
ifaces() { echo "${1}:1.0" "${1}:1.1"; }     # both interfaces of the camera
bound()  { [ -e "$DRV/$1" ]; }
unbind_cam() { local i; for i in $(ifaces "$1"); do bound "$i" && printf '%s' "$i" > "$DRV/unbind" 2>/dev/null || true; done; }
rebind_cam() { local i; for i in $(ifaces "$1"); do bound "$i" || printf '%s' "$i" > "$DRV/bind"   2>/dev/null || true; done; }

# read the privacy bit. format on this device: "privacy: 1" -> take the last field.
read_priv() {
  local v
  v="$(v4l2-ctl -d /dev/video0 -C privacy 2>/dev/null | awk -F': ' '{print $2}' | tr -dc '0-9')"
  printf '%s' "${v:-}"
}

while true; do
  base="$(find_devdir || true)"
  if [ -n "${base:-}" ]; then
    if [ -e /dev/video0 ]; then
      # camera bound -> if privacy is ON, cut it
      [ "$(read_priv)" = "1" ] && unbind_cam "$base"
    else
      # camera currently unbound (we cut it) -> briefly rebind to re-check the switch,
      # re-cut if still ON. This lets it auto-restore when you flip the switch OFF.
      rebind_cam "$base"
      sleep 0.4
      [ "$(read_priv)" = "1" ] && unbind_cam "$base"
    fi
  fi
  sleep "$POLL"
done
