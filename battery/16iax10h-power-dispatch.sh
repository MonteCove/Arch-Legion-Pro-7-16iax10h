#!/bin/sh
# /usr/local/bin/16iax10h-power-dispatch — AC/battery transition actions.
# Fired by udev via 16iax10h-power-dispatch.service on every Mains plug/unplug,
# at boot (multi-user, after docker), and at Hyprland session start (exec-once).
# Safe to run by hand, as root or as the user. Idempotent.
#
#   battery: internal OLED to 60 Hz (240 Hz scanout costs ~1-2 W)
#            stop the Frigate NVR docker stack (~0.5-1.5 W idle; useless off-LAN)
#   AC:      panel back to 240 Hz, start the NVR stack
#
# Note: 'hyprctl keyword' is a runtime override — a Hyprland config reload reverts
# to monitors.conf (240 Hz) until the next plug/unplug event or manual run.
set -u

USER_NAME=monte
USER_ID=1000
PANEL=eDP-2
MODE_AC="2560x1600@240"
MODE_BAT="2560x1600@60"

on_ac=0
for ps in /sys/class/power_supply/*; do
  [ "$(cat "$ps/type" 2>/dev/null)" = "Mains" ] || continue
  [ "$(cat "$ps/online" 2>/dev/null)" = "1" ] && on_ac=1
done

# --- panel refresh rate (needs a live Hyprland session) ---
mode="$MODE_AC"; [ "$on_ac" = 0 ] && mode="$MODE_BAT"
run="/run/user/$USER_ID"
sig="$(ls "$run/hypr" 2>/dev/null | head -1)"
if [ -n "$sig" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="$run" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
      hyprctl keyword monitor "$PANEL,$mode,auto,1" >/dev/null 2>&1 || true
  else
    hyprctl keyword monitor "$PANEL,$mode,auto,1" >/dev/null 2>&1 || true
  fi
fi

# --- Frigate NVR stack: AC-only (restart policy set to 'no' by the installer) ---
if command -v docker >/dev/null 2>&1; then
  if [ "$on_ac" = 1 ]; then
    docker start mosquitto frigate >/dev/null 2>&1 || true
  else
    docker stop frigate mosquitto >/dev/null 2>&1 || true
  fi
fi
exit 0
