#!/usr/bin/env bash
#
# raise-power-cap.sh  --  Lenovo Legion Pro 7 16IAX10H (Core Ultra 9 275HX)
#
# Lifts the ~30 W sustained CPU power cap by raising the Intel MMIO-RAPL package
# power limit, which was found set to 30 W and enabled while the MSR RAPL
# interface (170/210 W) was disabled:
#     /sys/class/powercap/intel-rapl-mmio:0  long_term=short_term=30 W, enabled=1
#
# This is the standard Linux powercap interface -- NOT an embedded-controller
# poke. It is independent of the legion-laptop driver. Safe on AC: the CPU's own
# ~100 C thermal throttle remains the hard backstop; worst case is more heat/fan.
#
# Usage:
#   sudo ./raise-power-cap.sh                  # apply (PL1=90 PL2=120) + verify under load
#   sudo ./raise-power-cap.sh --status         # show current limits, change nothing
#   sudo ./raise-power-cap.sh --pl1 80 --pl2 110
#   sudo ./raise-power-cap.sh --no-load        # apply without the load test
#   sudo ./raise-power-cap.sh --restore        # revert to the saved original limits
#   sudo ./raise-power-cap.sh --guard 10       # re-apply every 10s (if the EC claws it back)
#   sudo ./raise-power-cap.sh --sweep          # characterize sustained W per step (thermal-guarded)
#     sweep tuning: --steps "90 120 140" --runs 3 --max-temp 93 --sweep-load 34 --warmup 12
#   sudo ./raise-power-cap.sh --daemon         # follow Fn-Q mode + battery cap + thermal guard
#
set -uo pipefail

# ---- help works without root ----
case "${1:-}" in -h|--help) awk 'NR>1{ if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# ---- re-exec as root (preserving args) ----
if [ "$(id -u)" -ne 0 ]; then
  echo "raise-power-cap: elevating with sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ---- defaults (override via flags) ----
TARGET_PL1_W=90        # sustained (long_term)
TARGET_PL2_W=120       # burst (short_term)
LOAD_SECS=14
GUARD_INTERVAL=10
DO_LOAD=1
ACTION=apply
# sweep mode
SWEEP_STEPS="90 120 140 160"   # PL1 values (W) to characterize, ascending
SWEEP_LOAD=34                  # total seconds of load per step (warmup + measured window)
SWEEP_WARMUP=12                # seconds to let fans ramp before the measured window starts
SWEEP_RUNS=1                   # repeat each step N times and average (use 3 for robust numbers)
SWEEP_RUN_GAP=6                # cool-down seconds between repeats of the same step
MAX_TEMP=95                    # debounced abort: 2 consecutive samples >= this restores safe limit (10C below Tjmax)
HARD_TEMP=98                   # single-sample hard abort (7C below Tjmax 105)
COMFORT_TEMP=90                # recommend the highest step that stays <= this
SAFE_PL1=90                    # fallback limit used during abort / between steps
# daemon mode: map the Fn-Q power mode -> [PL1 PL2] watts, plus a closed-loop thermal guard
MODE_QUIET_PL1=45;    MODE_QUIET_PL2=60
MODE_BALANCED_PL1=90; MODE_BALANCED_PL2=110
MODE_PERF_PL1=130;    MODE_PERF_PL2=160   # ~the measured ~128W chassis ceiling; thermal guard backs it off if hot
BATTERY_MAX_PL1=90;   BATTERY_MAX_PL2=110 # on battery, cap PL1/PL2 to this regardless of Fn-Q mode (default = balanced)
DAEMON_POLL=3                  # seconds between checks
THERMAL_THROTTLE=96            # >= this C: step PL1 down to protect the chip
THERMAL_RECOVER=88             # <= this C: step PL1 back toward the mode target (hysteresis)
THROTTLE_STEP=15               # watts removed/restored per thermal step
THROTTLE_FLOOR=45              # never throttle PL1 below this
LEGION_DEV=/sys/bus/platform/devices/VPC2004:00

# ---- paths / state ----
real_user="${SUDO_USER:-root}"
real_home="$(getent passwd "$real_user" | cut -d: -f6)"; real_home="${real_home:-/root}"
STATE_DIR="$real_home/.local/share/legion-powercap"
LOGFILE="$STATE_DIR/powercap.log"
ORIG_FILE="$STATE_DIR/original_limits.env"
mkdir -p "$STATE_DIR"

# ---- logging ----
ts() { date '+%Y-%m-%d %H:%M:%S'; }
_color() { case "$1" in
  INFO) printf '\033[0;36m';; OK) printf '\033[0;32m';; WARN) printf '\033[0;33m';;
  ERR) printf '\033[0;31m';; STEP) printf '\033[1;35m';; *) printf '';; esac; }
log() {
  local lvl="$1"; shift; local msg="$*"
  printf '[%s] %-4s %s\n' "$(ts)" "$lvl" "$msg" >>"$LOGFILE" 2>/dev/null
  printf '%b[%s] %-4s\033[0m %s\n' "$(_color "$lvl")" "$(ts)" "$lvl" "$msg"
}
die() { log ERR "$*"; exit 1; }

# ---- helpers ----
uw2w() { awk -v v="${1:-}" 'BEGIN{ if(v=="") print "?"; else printf "%.0f", v/1000000 }'; }
w2uw() { echo $(( ${1} * 1000000 )); }
avg_mhz() { awk -F: '/MHz/{s+=$2;n++} END{ if(n) printf "%.0f", s/n; else print "?" }' /proc/cpuinfo; }

# --- CPU package temperature (coretemp "Package id 0" preferred, legion CPU temp fallback) ---
CPU_TEMP_FILE=""; CPU_SENSOR_TYPE=""
find_cpu_temp_file() {
  local h lf
  for h in /sys/class/hwmon/*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "coretemp" ] || continue
    for lf in "$h"/temp*_label; do
      [ -r "$lf" ] || continue
      [ "$(cat "$lf")" = "Package id 0" ] && {
        CPU_TEMP_FILE="${lf%_label}_input"; CPU_SENSOR_TYPE="coretemp"
        [ -r "$CPU_TEMP_FILE" ] && return 0; }
    done
  done
  CPU_TEMP_FILE="$(ls /sys/bus/platform/devices/VPC2004:00/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)"
  CPU_SENSOR_TYPE="legion-ec"
  [ -n "$CPU_TEMP_FILE" ] && [ -r "$CPU_TEMP_FILE" ]
}
# echoes integer C, or empty string on failure (callers treat empty as "unsafe -> abort")
cpu_temp_c() {
  local r; [ -n "$CPU_TEMP_FILE" ] || return 1
  r="$(cat "$CPU_TEMP_FILE" 2>/dev/null)" || return 1
  case "$r" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( r / 1000 ))
}
kill_load() {
  [ -n "${LOAD_PIDS[*]:-}" ] || return 0
  kill "${LOAD_PIDS[@]}" 2>/dev/null || true
  wait "${LOAD_PIDS[@]}" 2>/dev/null || true
}

find_mmio_pkg() {
  local d
  for d in /sys/class/powercap/intel-rapl-mmio:*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "package-0" ] && { echo "$d"; return 0; }
  done
  return 1
}

ENERGY_FILE=""; EMAX=0
pick_energy() {
  local d
  for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
    [ -r "$d/energy_uj" ] && head -c1 "$d/energy_uj" >/dev/null 2>&1 && {
      ENERGY_FILE="$d/energy_uj"
      EMAX="$(cat "${d}/max_energy_range_uj" 2>/dev/null)"
      case "${EMAX:-}" in ''|*[!0-9]*) EMAX=0 ;; esac
      return 0; }
  done
  return 1
}

LOAD_PIDS=(); LOAD_KIND=""
# returns non-zero if the load failed to start (so callers never measure a no-load run)
start_load() {
  LOAD_PIDS=()
  if command -v stress-ng >/dev/null 2>&1; then
    LOAD_KIND="stress-ng"
    stress-ng --cpu "$(nproc)" --timeout "${1}s" >/dev/null 2>&1 & LOAD_PIDS+=($!)
    sleep 0.2
    kill -0 "${LOAD_PIDS[0]}" 2>/dev/null || { log ERR "stress-ng did not start"; return 1; }
  else
    LOAD_KIND="bash-busyloop"
    local i
    for i in $(seq 1 "$(nproc)"); do timeout "$1" bash -c 'while :; do :; done' >/dev/null 2>&1 & LOAD_PIDS+=($!); done
    [ -n "${LOAD_PIDS[*]:-}" ] || { log ERR "busy-loop load did not start"; return 1; }
  fi
  return 0
}
stop_load() { [ -n "${LOAD_PIDS[*]:-}" ] && wait "${LOAD_PIDS[@]}" 2>/dev/null || true; }

# measure under sustained load: sets MEAS_MHZ, MEAS_W, MEAS_PL1_DURING
measure() {
  local secs="$1" tag="$2" mmio="$3"
  local win=$(( secs > 6 ? secs - 4 : 2 ))
  local e0 e1 pl0 pld
  pl0="$(cat "$mmio/constraint_0_power_limit_uw" 2>/dev/null)"
  start_load "$secs"
  sleep 2
  e0="$(cat "$ENERGY_FILE" 2>/dev/null)"
  sleep "$win"
  e1="$(cat "$ENERGY_FILE" 2>/dev/null)"
  MEAS_MHZ="$(avg_mhz)"
  pld="$(cat "$mmio/constraint_0_power_limit_uw" 2>/dev/null)"
  stop_load
  MEAS_W="?"
  if [ -n "$e0" ] && [ -n "$e1" ]; then
    MEAS_W="$(awk -v a="$e0" -v b="$e1" -v w="$win" -v m="$EMAX" \
      'BEGIN{ d=b-a; if(d<0){ if(m>0) d+=m; else { print "?"; exit } } printf "%.1f", d/(w*1000000) }')"
  fi
  MEAS_PL1_DURING="$pld"
  log OK   "[$tag] avg ${MEAS_MHZ} MHz   package ~${MEAS_W} W   (${LOAD_KIND}, ${win}s window)"
  log INFO "[$tag] PL1 during load: $(uw2w "$pld") W   (was $(uw2w "$pl0") W at start)"
}

show_state() {
  local m="$1" i nm
  log INFO "MMIO domain : $m   enabled=$(cat "$m/enabled" 2>/dev/null)"
  for i in 0 1 2; do
    [ -r "$m/constraint_${i}_name" ] || continue
    nm="$(cat "$m/constraint_${i}_name")"
    log INFO "  constraint_${i} ${nm}: limit=$(uw2w "$(cat "$m/constraint_${i}_power_limit_uw" 2>/dev/null)") W  max=$(uw2w "$(cat "$m/constraint_${i}_max_power_uw" 2>/dev/null)") W"
  done
  if [ -r /sys/class/powercap/intel-rapl:0/enabled ]; then
    log INFO "MSR domain  : intel-rapl:0   enabled=$(cat /sys/class/powercap/intel-rapl:0/enabled)  PL1=$(uw2w "$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null)") W"
  fi
  local ac; ac="$(cat /sys/class/power_supply/A{C,DP}*/online 2>/dev/null | head -1)"
  log INFO "AC adapter  : online=${ac:-unknown}"
}

write_limit() { # domain constraint_idx watts -> returns 0, logs readback
  local m="$1" idx="$2" w="$3" want got
  want="$(w2uw "$w")"
  if echo "$want" > "$m/constraint_${idx}_power_limit_uw" 2>>"$LOGFILE"; then :; else
    log WARN "write to constraint_${idx} returned an error"; fi
  got="$(cat "$m/constraint_${idx}_power_limit_uw" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    log OK "  constraint_${idx} -> $(uw2w "$got") W"
  else
    log WARN "  constraint_${idx} requested ${w} W but reads $(uw2w "$got") W (clamped to BIOS max?)"
  fi
}

# ----------------- actions -----------------
do_status() {
  local m; m="$(find_mmio_pkg)" || die "no intel-rapl-mmio package-0 domain found"
  log STEP "Current power-limit state"
  show_state "$m"
}

do_apply() {
  local m; m="$(find_mmio_pkg)" || die "no intel-rapl-mmio package-0 domain found"
  pick_energy || log WARN "no readable RAPL energy counter; reporting CPU MHz only (no watts)"

  log STEP "Before"
  show_state "$m"

  # capture the true original limits once
  local cur0 cur1; cur0="$(cat "$m/constraint_0_power_limit_uw")"; cur1="$(cat "$m/constraint_1_power_limit_uw")"
  if [ ! -f "$ORIG_FILE" ]; then
    local o0="$cur0" o1="$cur1"
    # if the governor daemon is running (or the limit is clearly already raised),
    # the live registers are NOT the firmware originals — record the verified 30 W
    # default instead, or --restore would "restore" to the raised values forever
    if systemctl is-active --quiet legion-powercapd.service 2>/dev/null || [ "${cur0:-0}" -gt 31000000 ] 2>/dev/null; then
      o0=30000000; o1=30000000
      log WARN "limits look already raised (daemon active or PL1>31W) -> recording 30 W firmware default as original"
    fi
    { echo "MMIO_PATH=$m"; echo "ORIG_PL1=$o0"; echo "ORIG_PL2=$o1"; } > "$ORIG_FILE"
    chown "$real_user" "$ORIG_FILE" 2>/dev/null || true
    log INFO "saved original limits to $ORIG_FILE (PL1=$(uw2w "$o0") W PL2=$(uw2w "$o1") W)"
  fi
  # shellcheck disable=SC1090
  . "$ORIG_FILE"

  if [ "$DO_LOAD" = 1 ]; then
    log STEP "Baseline (limits forced to original $(uw2w "$ORIG_PL1") W for a fair before/after)"
    # killed during the baseline window -> put the entry limits back instead of
    # leaving the machine clamped at the 30 W originals
    trap 'kill_load; echo "$cur0" > "$m/constraint_0_power_limit_uw" 2>/dev/null; echo "$cur1" > "$m/constraint_1_power_limit_uw" 2>/dev/null' EXIT INT TERM
    echo "$ORIG_PL1" > "$m/constraint_0_power_limit_uw" 2>/dev/null
    echo "$ORIG_PL2" > "$m/constraint_1_power_limit_uw" 2>/dev/null
    measure "$LOAD_SECS" "before" "$m"
    local base_mhz="$MEAS_MHZ" base_w="$MEAS_W"
    trap - EXIT INT TERM
  fi

  log STEP "Raising MMIO-RAPL limits -> PL1=${TARGET_PL1_W} W  PL2=${TARGET_PL2_W} W"
  write_limit "$m" 0 "$TARGET_PL1_W"
  write_limit "$m" 1 "$TARGET_PL2_W"

  if [ "$DO_LOAD" = 1 ]; then
    log STEP "After"
    measure "$LOAD_SECS" "after" "$m"
    local after_mhz="$MEAS_MHZ" after_w="$MEAS_W"

    # EC claw-back detection
    if [ -n "${MEAS_PL1_DURING:-}" ] && [ "${MEAS_PL1_DURING:-0}" -le 31000000 ] 2>/dev/null; then
      log WARN "PL1 fell back to ~30 W during load -- the EC is re-clamping the register."
      log WARN "Run with --guard 10 to hold it (foreground), or ask for a systemd guard service."
    fi

    log STEP "Summary"
    log INFO "before: ${base_mhz} MHz / ${base_w} W      after: ${after_mhz} MHz / ${after_w} W"
    local gained
    gained="$(awk -v b="${base_w:-0}" -v a="${after_w:-0}" 'BEGIN{ print (a+0 > b+0+5) ? 1 : 0 }')"
    if [ "$gained" = 1 ]; then
      log OK "CAP LIFTED -- sustained package power increased by ~$(awk -v b="${base_w:-0}" -v a="${after_w:-0}" 'BEGIN{printf "%.0f", a-b}') W"
    else
      log WARN "No clear power gain. Either clamped to a BIOS max, the EC re-clamped (see above), or 30 W comes from elsewhere."
    fi
  else
    log STEP "After"; show_state "$m"
  fi

  log INFO  "full log: $LOGFILE"
  log WARN "Runtime-only: resets on reboot. Re-run after boot, or ask me to install a systemd unit to persist it."
}

do_restore() {
  local m="" p1="" p2=""
  if [ -f "$ORIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ORIG_FILE"; m="${MMIO_PATH:-}"; p1="${ORIG_PL1:-}"; p2="${ORIG_PL2:-}"
  fi
  # stale/corrupt state (moved sysfs path, non-numeric values): fall back loudly
  if [ ! -e "$m/constraint_0_power_limit_uw" ] || ! [[ "$p1" =~ ^[0-9]+$ && "$p2" =~ ^[0-9]+$ ]]; then
    [ -f "$ORIG_FILE" ] && log WARN "saved originals unusable -> falling back to 30 W firmware default" \
                        || log WARN "no saved originals; restoring to 30 W default"
    m="$(find_mmio_pkg)" || die "no mmio domain"; p1=30000000; p2=30000000
  fi
  # write_limit reads the value back and warns on mismatch (no silent failure)
  write_limit "$m" 0 "$(( p1 / 1000000 ))"
  write_limit "$m" 1 "$(( p2 / 1000000 ))"
}

do_guard() {
  local m; m="$(find_mmio_pkg)" || die "no mmio domain"
  log STEP "Guard: holding PL1=${TARGET_PL1_W} W PL2=${TARGET_PL2_W} W every ${GUARD_INTERVAL}s (Ctrl-C to stop)"
  trap 'log INFO "guard stopped"; exit 0' INT TERM
  local n=0
  while :; do
    echo "$(w2uw "$TARGET_PL1_W")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
    echo "$(w2uw "$TARGET_PL2_W")" > "$m/constraint_1_power_limit_uw" 2>/dev/null
    n=$((n+1)); [ $((n % 6)) -eq 1 ] && log INFO "guard tick: PL1=$(uw2w "$(cat "$m/constraint_0_power_limit_uw")") W"
    sleep "$GUARD_INTERVAL"
  done
}

trip_guard() {  # write safe limit + kill load NOW (called the instant temp is unsafe)
  echo "$(w2uw "$SAFE_PL1")" > "$1/constraint_0_power_limit_uw" 2>/dev/null
  kill_load
}

# Sample temp for `dur` seconds at 0.5s cadence, updating G_TMAX (incl. the tripping sample).
# Abort rules: single sample >= HARD_TEMP, OR 2 consecutive >= MAX_TEMP, OR sensor unreadable.
# Returns 1 (and trips the guard) on abort, 0 otherwise.
G_TMAX=0; G_MHZ_SUM=0; G_MHZ_N=0
guarded_sample() {
  local dur="$1" mmio="$2" n t hi=0 mhz
  n=$(( dur * 2 )); [ "$n" -lt 1 ] && n=1
  while [ "$n" -gt 0 ]; do
    if ! t="$(cpu_temp_c)"; then log WARN "  temp sensor unreadable -- aborting step"; trip_guard "$mmio"; return 1; fi
    [ "$t" -gt "$G_TMAX" ] && G_TMAX="$t"
    if [ "$t" -ge "$HARD_TEMP" ]; then trip_guard "$mmio"; return 1; fi
    if [ "$t" -ge "$MAX_TEMP" ]; then hi=$(( hi + 1 )); [ "$hi" -ge 2 ] && { trip_guard "$mmio"; return 1; }
    else hi=0; fi
    mhz="$(avg_mhz)"; case "$mhz" in ''|*[!0-9]*) ;; *) G_MHZ_SUM=$(( G_MHZ_SUM + mhz )); G_MHZ_N=$(( G_MHZ_N + 1 )) ;; esac
    sleep 0.5; n=$(( n - 1 ))
  done
  return 0
}

# sweep one step: warm up (let fans ramp), then measure steady-state.
# sets: SW_W (delivered watts), SW_TMAX (max pkg C), SW_MHZ, SW_ABORT (0=ok,1=thermal,2=load-failed)
sweep_measure() {
  local secs="$1" mmio="$2"
  local e0 e1 t0 t1 abort=0 measure=$(( secs - SWEEP_WARMUP ))
  [ "$measure" -lt 4 ] && measure=4
  SW_W=0; SW_MHZ=0; SW_TMAX=0; SW_ABORT=0; G_TMAX=0
  if ! start_load "$secs"; then SW_ABORT=2; return 1; fi

  # phase 1: warm-up so the EC fan curve ramps before we judge steady-state
  if ! guarded_sample "$SWEEP_WARMUP" "$mmio"; then SW_TMAX="$G_TMAX"; SW_ABORT=1; return 0; fi

  # phase 2: measured steady-state window (windowed-average clock, not a single snapshot)
  G_MHZ_SUM=0; G_MHZ_N=0
  e0="$(cat "$ENERGY_FILE" 2>/dev/null)"; t0="$(date +%s)"
  guarded_sample "$measure" "$mmio" || abort=1
  e1="$(cat "$ENERGY_FILE" 2>/dev/null)"; t1="$(date +%s)"
  if [ "$G_MHZ_N" -gt 0 ]; then SW_MHZ=$(( G_MHZ_SUM / G_MHZ_N )); else SW_MHZ="$(avg_mhz)"; fi
  [ "$abort" = 1 ] || stop_load

  local dt=$(( t1 - t0 )); [ "$dt" -lt 1 ] && dt=1
  if [ -n "$e0" ] && [ -n "$e1" ]; then
    SW_W="$(awk -v a="$e0" -v b="$e1" -v dt="$dt" -v m="$EMAX" \
      'BEGIN{ d=b-a; if(d<0){ if(m>0) d+=m; else {print "0"; exit} } printf "%.0f", d/(dt*1000000) }')"
  fi
  SW_TMAX="$G_TMAX"; SW_ABORT="$abort"
}

do_sweep() {
  local m; m="$(find_mmio_pkg)" || die "no intel-rapl-mmio package-0 domain found"
  pick_energy || die "sweep needs a readable RAPL energy counter (run as root)"
  if find_cpu_temp_file; then
    log INFO "thermal guard sensor: ${CPU_SENSOR_TYPE} (${CPU_TEMP_FILE})"
    if [ "$CPU_SENSOR_TYPE" = "legion-ec" ]; then
      [ "$MAX_TEMP" -gt 92 ] && MAX_TEMP=92
      log WARN "slower legion EC sensor in use -- abort threshold lowered to ${MAX_TEMP}C for margin"
    fi
  else
    die "no readable CPU temperature sensor -- refusing to sweep without a thermal guard"
  fi

  local ac; ac="$(cat /sys/class/power_supply/A{C,DP}*/online 2>/dev/null | head -1)"
  [ "$ac" = "1" ] || log WARN "AC not detected online -- sweep results on battery are meaningless; plug in."

  # remember the limit we came in with, restore it at the end
  local cur0 cur1; cur0="$(cat "$m/constraint_0_power_limit_uw")"; cur1="$(cat "$m/constraint_1_power_limit_uw")"
  # Ctrl-C / kill mid-sweep must NOT leave a 160 W step applied with the guard gone:
  # kill the load and restore the entry limits on any exit path
  trap 'kill_load; echo "$cur0" > "$m/constraint_0_power_limit_uw" 2>/dev/null; echo "$cur1" > "$m/constraint_1_power_limit_uw" 2>/dev/null; log WARN "sweep interrupted -- entry limits restored"; exit 130' INT TERM
  trap 'kill_load; echo "$cur0" > "$m/constraint_0_power_limit_uw" 2>/dev/null; echo "$cur1" > "$m/constraint_1_power_limit_uw" 2>/dev/null' EXIT

  log STEP "Power sweep: steps=[${SWEEP_STEPS}] W  ${SWEEP_RUNS} run(s)/step  ${SWEEP_WARMUP}s warmup + $(( SWEEP_LOAD - SWEEP_WARMUP ))s measure  abort: 2x>=${MAX_TEMP}C or 1x>=${HARD_TEMP}C  start=$(cpu_temp_c)C"
  log INFO "$(printf '%-8s %-11s %-9s %-8s %s' 'PL1set' 'deliveredW' 'maxTempC' 'avgMHz' 'verdict')"

  local pl pl2 best_sustained=0 best_comfort=0 ratio verdict r
  for pl in $SWEEP_STEPS; do
    pl2="$pl"   # PL2=PL1 during the sweep: no onset burst, so we measure the true sustained draw
    echo "$(w2uw "$pl")"  > "$m/constraint_0_power_limit_uw" 2>/dev/null
    echo "$(w2uw "$pl2")" > "$m/constraint_1_power_limit_uw" 2>/dev/null

    # repeat the step SWEEP_RUNS times and average (delivered W, clock); take the worst temp
    local rsumW=0 rsumMHz=0 rmaxT=0 rok=0 raborted=0 rloadfail=0
    for r in $(seq 1 "$SWEEP_RUNS"); do
      sweep_measure "$SWEEP_LOAD" "$m"
      if [ "$SW_ABORT" = 2 ]; then rloadfail=1; break; fi
      [ "$SW_TMAX" -gt "$rmaxT" ] && rmaxT="$SW_TMAX"
      if [ "$SW_ABORT" = 1 ]; then raborted=1; break; fi
      rsumW=$(( rsumW + SW_W )); rsumMHz=$(( rsumMHz + SW_MHZ )); rok=$(( rok + 1 ))
      if [ "$r" -lt "$SWEEP_RUNS" ]; then        # brief recover between repeats
        echo "$(w2uw "$SAFE_PL1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
        sleep "$SWEEP_RUN_GAP"
        echo "$(w2uw "$pl")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
      fi
    done
    [ "$rloadfail" = 1 ] && { log ERR "load failed to start -- aborting sweep"; break; }

    local avgW=0 avgMHz=0
    [ "$rok" -gt 0 ] && { avgW=$(( rsumW / rok )); avgMHz=$(( rsumMHz / rok )); }
    if [ "$raborted" = 1 ]; then
      verdict="THERMAL-ABORT (>=${MAX_TEMP}C)"
    else
      ratio="$(awk -v d="$avgW" -v s="$pl" 'BEGIN{ if(s>0) printf "%.2f", d/s; else print 0 }')"
      if awk -v r="$ratio" 'BEGIN{ exit !(r>=0.90) }'; then
        verdict="sustained"; best_sustained="$pl"
        [ "$rmaxT" -le "$COMFORT_TEMP" ] && best_comfort="$pl"
      else
        verdict="cooling-limited (~${avgW}W delivered)"
      fi
    fi
    log OK "$(printf '%-8s %-11s %-9s %-8s %s' "${pl}W" "${avgW}W" "${rmaxT}C" "${avgMHz}" "$verdict")"
    [ "$raborted" = 1 ] && { log WARN "thermal abort -- ending sweep"; break; }

    # cool-down to a known-cool baseline before the next (higher) step
    echo "$(w2uw "$SAFE_PL1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
    sleep 10
    local bt; bt="$(cpu_temp_c || echo '?')"
    if [ "$bt" != '?' ] && [ "$bt" -gt 80 ]; then
      log INFO "  baseline still ${bt}C; extending cool-down"; sleep 8
    fi
  done

  # restore the entry limits (do not leave the sweep's last step applied)
  trap - EXIT INT TERM
  echo "$cur0" > "$m/constraint_0_power_limit_uw" 2>>"$LOGFILE" || log WARN "FAILED to restore PL1 -- check $m/constraint_0_power_limit_uw"
  echo "$cur1" > "$m/constraint_1_power_limit_uw" 2>>"$LOGFILE" || log WARN "FAILED to restore PL2"

  log STEP "Sweep result"
  if [ "$best_comfort" -gt 0 ]; then
    log OK "Recommended sustained target: PL1=${best_comfort}W (highest step holding <=${COMFORT_TEMP}C)."
    log INFO "Apply with:  $0 --pl1 ${best_comfort} --pl2 $(( best_comfort + 30 ))   then enable the service."
  elif [ "$best_sustained" -gt 0 ]; then
    log WARN "Highest fully-delivered step was ${best_sustained}W but it ran hot (>${COMFORT_TEMP}C). Consider ${best_sustained}W only with aggressive cooling, else stay at ${SAFE_PL1}W."
  else
    log WARN "No step delivered its full limit -- the chassis tops out around the delivered watts shown above; ${SAFE_PL1}W is a safe pick."
  fi
  log INFO "Limits restored to entry values (PL1=$(uw2w "$cur0")W). Nothing left applied by the sweep."
  log INFO "full log: $LOGFILE"
}

# read the active Fn-Q power mode: echoes quiet|balanced|performance|custom|unknown
# prefers the standard platform_profile interface, falls back to the legion EC powermode
read_mode() {
  local p="" f pm
  if [ -r /sys/firmware/acpi/platform_profile ]; then
    p="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
  else
    f="$(ls /sys/class/platform-profile/*/profile 2>/dev/null | head -1)"
    [ -n "$f" ] && p="$(cat "$f" 2>/dev/null)"
  fi
  if [ -n "$p" ]; then
    case "$p" in
      low-power|quiet|cool) echo quiet ;;
      balanced|balanced-performance) echo balanced ;;
      performance|max-power) echo performance ;;
      *) echo "$p" ;;
    esac
    return
  fi
  pm="$(cat "$LEGION_DEV/powermode" 2>/dev/null)"
  case "$pm" in 1) echo quiet ;; 2) echo balanced ;; 3) echo performance ;; 255) echo custom ;; *) echo unknown ;; esac
}

# echoes 1 if running on AC (Mains online), 0 on battery; assumes AC if no Mains supply exists
read_ac() {
  local p o
  for p in /sys/class/power_supply/*; do
    [ "$(cat "$p/type" 2>/dev/null)" = "Mains" ] || continue
    o="$(cat "$p/online" 2>/dev/null)"
    case "$o" in 0|1) echo "$o"; return ;; esac
  done
  echo 1
}

# governor: apply the mode's power limit and hold the chip under THERMAL_THROTTLE.
do_daemon() {
  local m; m="$(find_mmio_pkg)" || die "no intel-rapl-mmio package-0 domain found"
  find_cpu_temp_file || die "no CPU temperature sensor -- daemon refuses to run without a thermal guard"
  log STEP "legion-powercapd: poll=${DAEMON_POLL}s  throttle>=${THERMAL_THROTTLE}C  recover<=${THERMAL_RECOVER}C  floor=${THROTTLE_FLOOR}W  sensor=${CPU_SENSOR_TYPE}"
  log INFO "modes: quiet=${MODE_QUIET_PL1}W balanced=${MODE_BALANCED_PL1}W performance=${MODE_PERF_PL1}W  battery-cap=${BATTERY_MAX_PL1}W"

  local last_key="" eff1=0 eff2=0 cur1=0 throttled=0 mode ac temp t1 t2 live1 live2 drift_n=0 fb=0
  trap 'log INFO "legion-powercapd stopping"; exit 0' INT TERM
  while :; do
    mode="$(read_mode)"
    ac="$(read_ac)"
    case "$mode" in
      quiet)       t1=$MODE_QUIET_PL1;    t2=$MODE_QUIET_PL2 ;;
      performance) t1=$MODE_PERF_PL1;     t2=$MODE_PERF_PL2 ;;
      custom)      t1=$MODE_PERF_PL1;     t2=$MODE_PERF_PL2 ;;   # custom -> treat as performance
      *)           t1=$MODE_BALANCED_PL1; t2=$MODE_BALANCED_PL2 ;; # balanced / unknown
    esac
    # on battery, cap to the battery ceiling regardless of mode
    eff1=$t1; eff2=$t2
    if [ "$ac" = 0 ]; then
      [ "$eff1" -gt "$BATTERY_MAX_PL1" ] && eff1=$BATTERY_MAX_PL1
      [ "$eff2" -gt "$BATTERY_MAX_PL2" ] && eff2=$BATTERY_MAX_PL2
    fi

    # (re)apply whenever mode, power source, or the resulting target changes
    local key="${mode}/${ac}/${eff1}/${eff2}"
    if [ "$key" != "$last_key" ]; then
      echo "$(w2uw "$eff1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
      echo "$(w2uw "$eff2")" > "$m/constraint_1_power_limit_uw" 2>/dev/null
      cur1=$eff1; throttled=0; last_key="$key"
      log OK "mode=${mode} $([ "$ac" = 1 ] && echo AC || echo BATTERY) -> PL1=${eff1}W PL2=${eff2}W"
    fi

    # firmware/EC can silently reset the registers (resume, EC claw-back) without
    # the mode/AC key changing — read back and re-assert whenever the live values
    # differ from what we intend (PL1=cur1 incl. any thermal throttle, PL2=eff2)
    live1="$(cat "$m/constraint_0_power_limit_uw" 2>/dev/null)"
    live2="$(cat "$m/constraint_1_power_limit_uw" 2>/dev/null)"
    if [ "$live1" != "$(w2uw "$cur1")" ] || [ "$live2" != "$(w2uw "$eff2")" ]; then
      echo "$(w2uw "$cur1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
      echo "$(w2uw "$eff2")" > "$m/constraint_1_power_limit_uw" 2>/dev/null
      drift_n=$(( drift_n + 1 ))
      # log the first drift and then every 20th, so a constantly-clamping EC
      # doesn't flood the journal at poll rate
      if [ "$drift_n" -eq 1 ] || [ $(( drift_n % 20 )) -eq 0 ]; then
        log WARN "limits drifted (PL1 read $(uw2w "${live1:-}") W, drift #${drift_n}) -> re-applied PL1=${cur1}W PL2=${eff2}W"
      fi
    fi

    # thermal guard rides on top, never above the current effective target (eff1)
    if temp="$(cpu_temp_c)"; then
      if [ "$temp" -ge "$THERMAL_THROTTLE" ] && [ "$cur1" -gt "$THROTTLE_FLOOR" ]; then
        cur1=$(( cur1 - THROTTLE_STEP )); [ "$cur1" -lt "$THROTTLE_FLOOR" ] && cur1=$THROTTLE_FLOOR
        echo "$(w2uw "$cur1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
        throttled=1
        log WARN "thermal ${temp}C >= ${THERMAL_THROTTLE}C -> PL1 throttled to ${cur1}W"
      elif [ "$throttled" = 1 ] && [ "$temp" -le "$THERMAL_RECOVER" ] && [ "$cur1" -lt "$eff1" ]; then
        cur1=$(( cur1 + THROTTLE_STEP )); [ "$cur1" -gt "$eff1" ] && cur1=$eff1
        echo "$(w2uw "$cur1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
        [ "$cur1" -ge "$eff1" ] && throttled=0
        log OK "thermal ${temp}C <= ${THERMAL_RECOVER}C -> PL1 restored to ${cur1}W"
      fi
    else
      # never RAISE the limit on a sensor failure: hold the LOWEST of the safe
      # value, the mode target, and the current (possibly throttled) limit —
      # a sensor glitch during an overheat must not undo the throttle
      fb=$SAFE_PL1
      [ "$eff1" -gt 0 ] && [ "$eff1" -lt "$fb" ] && fb=$eff1
      [ "$cur1" -gt 0 ] && [ "$cur1" -lt "$fb" ] && fb=$cur1
      echo "$(w2uw "$fb")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
      [ "$fb" -lt "$eff1" ] && throttled=1
      cur1=$fb
      log WARN "CPU temp unreadable -> holding PL1 at ${fb}W (min of safe/mode/current)"
    fi
    sleep "$DAEMON_POLL"
  done
}

# ----------------- arg parse -----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --status)   ACTION=status ;;
    --restore)  ACTION=restore ;;
    --guard)    ACTION=guard; [[ "${2:-}" =~ ^[0-9]+$ ]] && { GUARD_INTERVAL="$2"; shift; } ;;
    --pl1)      TARGET_PL1_W="${2:?}"; shift ;;
    --pl2)      TARGET_PL2_W="${2:?}"; shift ;;
    --no-load)  DO_LOAD=0 ;;
    --load-secs) LOAD_SECS="${2:?}"; shift ;;
    --sweep)    ACTION=sweep ;;
    --daemon)   ACTION=daemon ;;
    --steps)    SWEEP_STEPS="${2:?}"; shift ;;
    --max-temp) MAX_TEMP="${2:?}"; shift ;;
    --sweep-load) SWEEP_LOAD="${2:?}"; shift ;;
    --warmup)   SWEEP_WARMUP="${2:?}"; shift ;;
    --runs)     SWEEP_RUNS="${2:?}"; shift ;;
    -h|--help)  awk 'NR>1{ if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)          echo "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

chown "$real_user" "$STATE_DIR" "$LOGFILE" 2>/dev/null || true
log STEP "raise-power-cap.sh  action=${ACTION}  (user=${real_user})"
case "$ACTION" in
  status)  do_status ;;
  apply)   do_apply ;;
  restore) do_restore ;;
  guard)   do_guard ;;
  sweep)   do_sweep ;;
  daemon)  do_daemon ;;
esac
