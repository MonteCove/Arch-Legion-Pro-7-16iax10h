#!/bin/sh
# /usr/local/bin/16iax10h-battery-guard.sh
# Low-battery warner + last-resort auto-hibernate for the Legion Pro 7 16IAX10H.
# Runs as a per-user systemd service (needs the session bus for notify-send and
# for logind to authorize hibernate). Polls BAT0 every 60s while AWAKE.
#
# Thresholds (discharging only):  20% notify  /  10% urgent  /  5% act.
# At 5% it hibernates (saves to disk, powers off cleanly) if hibernation is
# configured; otherwise it does a clean poweroff. Either way: no more silent death.
#
# Note: this guards the AWAKE case. The SUSPENDED case (lid closed / idle-suspend)
# is covered by suspend-then-hibernate (systemd hibernates before the battery dies).

BAT=/sys/class/power_supply/BAT0
POLL="${BATTERY_GUARD_POLL:-60}"
LOW="${BATTERY_GUARD_LOW:-20}"
CRIT="${BATTERY_GUARD_CRIT:-10}"
ACT="${BATTERY_GUARD_ACT:-5}"

[ -r "$BAT/capacity" ] || { echo "no $BAT; exiting"; exit 0; }

note() { command -v notify-send >/dev/null 2>&1 && notify-send "$@" 2>/dev/null || true; }

# estimate time left while discharging -> "~3h24m left" (energy/power or charge/current),
# falling back to upower; empty string if it can't be computed.
time_left() {
    en="$(cat "$BAT/energy_now" 2>/dev/null)"; pw="$(cat "$BAT/power_now" 2>/dev/null)"
    [ -z "$en" ] && en="$(cat "$BAT/charge_now" 2>/dev/null)"
    [ -z "$pw" ] && pw="$(cat "$BAT/current_now" 2>/dev/null)"
    if [ -n "$en" ] && [ -n "$pw" ] && [ "$pw" -gt 0 ] 2>/dev/null; then
        awk -v e="$en" -v p="$pw" 'BEGIN{ m=e/p*60; printf "~%dh%02dm left", int(m/60), int(m)%60 }'
        return
    fi
    command -v upower >/dev/null 2>&1 && upower -i "$(upower -e 2>/dev/null | grep -m1 BAT)" 2>/dev/null \
        | awk -F: '/time to empty/{gsub(/^[ \t]+/,"",$2); printf "~%s left", $2}'
}

can_hibernate() {
    # hibernation works only if a real (non-zram) swap + resume target exists
    grep -q 'resume=' /proc/cmdline 2>/dev/null || return 1
    awk '$1!~/zram/ && $2=="partition" || $2=="file"{found=1} END{exit !found}' /proc/swaps 2>/dev/null
}

said_low=0 said_crit=0
while :; do
    cap="$(cat "$BAT/capacity" 2>/dev/null || echo 100)"
    st="$(cat "$BAT/status" 2>/dev/null || echo Unknown)"
    case "$st" in
        Discharging)
            if [ "$cap" -le "$ACT" ]; then
                if can_hibernate; then
                    note -u critical -t 0 "🔋 Battery critical (${cap}%)" "Hibernating now to protect your work."
                    sleep 5
                    systemctl hibernate 2>/dev/null || systemctl poweroff
                else
                    note -u critical -t 0 "🔋 Battery critical (${cap}%)" "Shutting down now (no hibernation configured)."
                    sleep 5
                    systemctl poweroff
                fi
            elif [ "$cap" -le "$CRIT" ] && [ "$said_crit" = 0 ]; then
                note -u critical "🔋 Battery very low (${cap}%)" "$(time_left). Plug in now — auto-action at ${ACT}%."
                said_crit=1
            elif [ "$cap" -le "$LOW" ] && [ "$said_low" = 0 ]; then
                note -u normal "🔋 Battery low (${cap}%)" "$(time_left). Consider plugging in the charger."
                said_low=1
            fi
            ;;
        *)
            # charging / full / not-discharging: re-arm the one-shot warnings
            said_low=0; said_crit=0
            ;;
    esac
    sleep "$POLL"
done
