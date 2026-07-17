#!/usr/bin/env bash
# camera-privacy-guard.sh — make the Lenovo camera privacy switch ACTUALLY block the
# camera. On this Legion the switch sets V4L2 privacy=1 but uvcvideo keeps streaming
# (privacy theater). This watcher polls the privacy bit and unbinds the uvcvideo USB
# interface when privacy is ON (so the video nodes vanish and capture gets ENODEV),
# rebinding when OFF. Match by VID:PID so it's port-independent, and resolve the
# video node from sysfs so an external webcam can never confuse it.
#
# Honest limits (see README): detection is polling — a V4L2 control change emits no
# event we can wait on while the device is unbound.
#   camera usable : switch checked every POLL s (flip-to-cut latency <= POLL)
#   camera cut    : switch re-read every RECHECK s by briefly rebinding; the node is
#                   openable for the ~0.2-0.4 s the re-check takes. Duty cycle ~2%.
# Tune with CAM_GUARD_POLL / CAM_GUARD_RECHECK (lower = faster reaction, more USB
# wakeups — the old 1 s poll kept the webcam from ever autosuspending, ~0.3-0.6 W).
# Failure policy: if the privacy bit can't be read 3x in a row, the camera is CUT
# (fail closed) and the reason is logged to the journal.
#
# Verified on-device: camera 30c9:00f8; BOTH video nodes live on iface :1.0.
set -uo pipefail
VID=30c9
PID=00f8
DRV=/sys/bus/usb/drivers/uvcvideo
POLL="${CAM_GUARD_POLL:-10}"        # s between privacy checks while camera is usable
RECHECK="${CAM_GUARD_RECHECK:-20}"  # s between switch re-checks while camera is cut

log() { printf 'camera-privacy-guard: %s\n' "$*"; }   # stdout -> journald

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
unbind_cam() { local i; for i in $(ifaces "$1"); do
    if bound "$i"; then printf '%s' "$i" > "$DRV/unbind" 2>/dev/null || log "WARNING: unbind of $i failed"; fi
  done; }
rebind_cam() { local i; for i in $(ifaces "$1"); do
    if ! bound "$i"; then printf '%s' "$i" > "$DRV/bind" 2>/dev/null || log "WARNING: bind of $i failed"; fi
  done; }

# /dev/videoN of the camera's :1.0 interface — never a hardcoded index (an external
# webcam that enumerates first would own /dev/video0)
video_node() {
  local n
  n="$(ls "/sys/bus/usb/devices/${1}:1.0/video4linux" 2>/dev/null | sort | head -1)"
  [ -n "$n" ] && printf '/dev/%s' "$n"
}

# read the privacy bit ("privacy: 1" -> last field). echoes 0/1, empty on failure.
read_priv() {
  local v
  v="$(v4l2-ctl -d "$1" -C privacy 2>/dev/null | awk -F': ' '{print $2}' | tr -dc '0-9')"
  printf '%s' "${v:-}"
}

command -v v4l2-ctl >/dev/null 2>&1 \
  || log "WARNING: v4l2-ctl not found — the privacy bit is unreadable, guard will fail closed"

fails=0
while true; do
  base="$(find_devdir || true)"
  if [ -z "${base:-}" ]; then sleep "$POLL"; continue; fi   # camera not present

  if bound "${base}:1.0"; then
    # camera usable -> check the switch; cut on ON or on persistent read failure
    node="$(video_node "$base" || true)"
    if [ -z "${node:-}" ] || [ ! -e "$node" ]; then sleep 1; continue; fi  # still enumerating
    p="$(read_priv "$node")"
    if [ "$p" = "1" ]; then
      log "privacy switch ON -> cutting camera ($base)"
      unbind_cam "$base"; fails=0
    elif [ -z "$p" ]; then
      fails=$((fails+1))
      log "WARNING: cannot read privacy bit from $node (attempt $fails/3)"
      if [ "$fails" -ge 3 ]; then
        log "WARNING: privacy state unreadable 3x -> cutting camera (fail closed)"
        unbind_cam "$base"; fails=0
      fi
    else
      fails=0
    fi
    sleep "$POLL"
  else
    # camera cut by us -> briefly rebind to re-read the switch, re-cut ASAP if still ON
    rebind_cam "$base"
    node=""; n=0
    while [ "$n" -lt 20 ]; do            # wait max 1 s, in 50 ms steps, for the node
      node="$(video_node "$base" || true)"
      [ -n "${node:-}" ] && [ -e "$node" ] && break
      sleep 0.05; n=$((n+1))
    done
    p=""
    [ -n "${node:-}" ] && [ -e "$node" ] && p="$(read_priv "$node")"
    if [ "$p" = "0" ]; then
      log "privacy switch OFF -> camera restored"
    else
      [ -z "$p" ] && log "WARNING: privacy unreadable during re-check -> keeping camera cut (fail closed)"
      unbind_cam "$base"
    fi
    sleep "$RECHECK"
  fi
done
