#!/bin/sh
# /usr/local/bin/16iax10h-idle-sleep.sh
# AC-aware idle action for hypridle's long-idle listener.
#
#   On AC power : do NOTHING -- stay on. (The earlier hypridle listeners have
#                 already dimmed, turned the screen off, and locked the session,
#                 which is all we want while plugged in.)
#   On battery  : suspend-then-hibernate, so the laptop deep-sleeps and then saves
#                 to disk + powers off before the battery can drain to death.
#
# This is why a plugged-in laptop keeps running (downloads, builds, remote access)
# while an unplugged one protects itself.

on_ac=0
for ps in /sys/class/power_supply/*; do
    [ "$(cat "$ps/type" 2>/dev/null)" = "Mains" ] || continue
    [ "$(cat "$ps/online" 2>/dev/null)" = "1" ] && on_ac=1
done

[ "$on_ac" = 1 ] && exit 0   # plugged in -> stay awake

exec systemctl suspend-then-hibernate
