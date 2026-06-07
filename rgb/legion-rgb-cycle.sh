#!/usr/bin/env bash
# Cycle keyboard lighting like Windows' Fn+Space. Bind this to a key in Hyprland.
#
# Default: cycle through your SAVED Legion RGB Studio profiles (most Windows-like).
# Fallback (if you have <2 saved profiles): cycle the 3 hardware backlight levels.
#
# Usage:  legion-rgb-cycle.sh           # next profile (or next brightness level)
#         legion-rgb-cycle.sh bright    # force brightness-level cycle only
set -uo pipefail
CTL=/usr/local/bin/spectrum-ctl
STUDIO=/opt/legion-rgb-studio/legion-rgb-studio.py
PROFILES="$HOME/.config/legion-rgb-studio/profiles.json"
STATE="$HOME/.config/legion-rgb-studio/.cycle_state"

notify(){ command -v notify-send >/dev/null 2>&1 && \
  notify-send -t 1500 -h string:x-canonical-private-synchronous:rgb "⌨ Keyboard Lighting" "$1" 2>/dev/null || true; }

cycle_brightness(){
  local cur n lbl
  cur="$(sudo "$CTL" status 2>/dev/null | sed -n 's/.*[Bb]rightness[^0-9]*\([0-9]\).*/\1/p')"
  cur="${cur:-0}"
  if   [ "$cur" -eq 0 ]; then n=3; lbl="Low"
  elif [ "$cur" -le 5 ]; then n=9; lbl="High"
  else n=0; lbl="Off"; fi
  sudo "$CTL" brightness "$n" >/dev/null 2>&1
  notify "Brightness: $lbl"
}

# --- profile cycle (preferred) ---
if [ "${1:-}" != "bright" ] && [ -f "$PROFILES" ] && [ -f "$STUDIO" ] && command -v python >/dev/null 2>&1; then
  names="$(python - "$PROFILES" <<'PY'
import json, sys
try: print("\n".join(json.load(open(sys.argv[1])).get("profiles", {}).keys()))
except Exception: pass
PY
)"
  if [ "$(printf '%s\n' "$names" | grep -c .)" -ge 2 ]; then
    last="$(cat "$STATE" 2>/dev/null || true)"
    next="$(printf '%s\n' "$names" | awk -v last="$last" '
      {a[NR]=$0} END{for(i=1;i<=NR;i++) if(a[i]==last){print (i<NR)?a[i+1]:a[1]; ok=1} if(!ok) print a[1]}')"
    printf '%s' "$next" > "$STATE"
    python - "$PROFILES" "$next" <<'PY'
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("studio", "/opt/legion-rgb-studio/legion-rgb-studio.py")
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
state = json.load(open(sys.argv[1]))["profiles"].get(sys.argv[2])
if state: st.apply_state(state)
PY
    notify "Profile: $next"
    exit 0
  fi
fi

# --- fallback: brightness levels ---
cycle_brightness
