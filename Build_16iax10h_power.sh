#!/usr/bin/env bash
#
# Build_16iax10h_power.sh
# One-shot, idempotent installer for the Lenovo Legion Pro 7 16IAX10H (Q7CN, EC IT5508)
# power / fan / Fn-Q-mode solution on a fresh Arch Linux install.
#
# It performs, with dependency checks, error checking, logging and skip-on-done:
#   1. preflight  - verify model (product 83F5 / BIOS Q7CN|SMCN) and kernel build support
#   2. deps       - pacman -S --needed base-devel git lm_sensors stress-ng
#   3. source     - clone gluceri/legion-pro-7-16iax10h-linux
#   4. patch      - bind legion-laptop to VPC2004 (instead of PNP0C09, which acpi-ec owns)
#   5. build      - compile legion-laptop.ko against the running kernel
#   6. install    - install the module + depmod
#   7. configs    - modprobe options (enable_platformprofile), blacklists (lenovo-wmi, ideapad),
#                   autoload (legion-laptop + coretemp)
#   8. tool       - install the power governor to /usr/local/bin/legion-powercap
#   9. service    - install + enable legion-powercapd.service (follows Fn-Q mode + thermal guard)
#  10. activate   - bind legion + start the governor now (no reboot needed, best effort)
#
# The governor maps the Fn-Q power mode to the Intel MMIO-RAPL CPU power limit
# (quiet 45W / balanced 90W / performance 130W), throttles on temperature, and
# caps to balanced when on battery. The 130W performance target matches the
# measured ~128W sustained chassis ceiling; the CPU's ~105C Tjmax throttle is the
# hard backstop.
#
# Usage:
#   ./Build_16iax10h_power.sh                 # full install (safe to re-run)
#   ./Build_16iax10h_power.sh --verify        # read-only check (great after a reboot); no sudo
#   ./Build_16iax10h_power.sh --force         # re-clone + rebuild everything
#   ./Build_16iax10h_power.sh --skip-activate # configure only; apply at next boot
#
# Run as your NORMAL user (it uses sudo per-step). Requires a kernel that exposes
# /sys/class/powercap/intel-rapl-mmio and matching kernel headers (-headers package).
#
set -uo pipefail

# ---- help works without sudo ----
case "${1:-}" in -h|--help) sed -n '2,33p' "$0"; exit 0 ;; esac

# ---- must run as the normal user; we elevate per-step with sudo ----
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not as root/sudo (it calls sudo per-step)." >&2
  exit 1
fi
SUDO="sudo"

# ============================ config ============================
REPO_URL="https://github.com/gluceri/legion-pro-7-16iax10h-linux.git"
REPO_DIR="${LEGION_REPO_DIR:-$HOME/legion-pro-7-16iax10h-linux}"
TOOL_DST="/usr/local/bin/legion-powercap"
SERVICE_NAME="legion-powercapd.service"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}"
OLD_ONESHOT="legion-powercap.service"
EXPECT_PRODUCT="83F5"               # Legion Pro 7 16IAX10H
EXPECT_BIOS_PREFIXES="Q7CN SMCN"    # Q7CN (Intel) / SMCN (AMD sibling)
KREL="$(uname -r)"
KBUILD="/lib/modules/${KREL}/build"

FORCE=0
SKIP_ACTIVATE=0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/legion-powercap-install"
LOGFILE="$STATE_DIR/install.log"

# ============================ logging ============================
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
_logf(){ printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || true; }
step() { printf '\033[1;35m==>\033[0m %s\n' "$*"; _logf "[$(ts)] ==> $*"; }
log()  { printf '    %s\n' "$*";              _logf "[$(ts)]     $*"; }
warn() { printf '    \033[1;33mwarning:\033[0m %s\n' "$*"; _logf "[$(ts)]     warning: $*"; }
err()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2;      _logf "[$(ts)] !!! $*"; }
die()  { err "$*"; err "steps already completed are skipped on re-run; fix the issue and re-run."; exit 1; }

# ============================ helpers ============================
have() { command -v "$1" >/dev/null 2>&1; }

# write $2 (content) to file $1 via sudo, idempotently (skip if identical)
write_file() {
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
    log "skip: $path already up to date"; return 0
  fi
  printf '%s\n' "$content" | $SUDO tee "$path" >/dev/null || die "could not write $path"
  log "wrote $path"
}

# ============================ steps ============================
preflight() {
  step "Preflight checks"
  local prod fam bios biosok=0 p
  prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  fam="$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)"
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  log "product=${prod:-?}  family=${fam:-?}  bios=${bios:-?}  kernel=${KREL}"
  for p in $EXPECT_BIOS_PREFIXES; do case "$bios" in ${p}*) biosok=1 ;; esac; done
  if [ "$prod" != "$EXPECT_PRODUCT" ] || [ "$biosok" != 1 ]; then
    if [ "$FORCE" = 1 ]; then
      warn "machine does not look like ${EXPECT_PRODUCT}/${EXPECT_BIOS_PREFIXES} -- proceeding due to --force"
    else
      die "this installer is specific to the Legion Pro 7 16IAX10H (product ${EXPECT_PRODUCT}, BIOS ${EXPECT_BIOS_PREFIXES}*). Detected product='${prod}' bios='${bios}'. Use --force only if you are certain it matches."
    fi
  else
    log "machine matches Legion Pro 7 16IAX10H"
  fi
  if [ ! -d "$KBUILD" ]; then
    die "no kernel headers for ${KREL} (missing ${KBUILD}). Install them and re-run: stock kernel -> 'sudo pacman -S --needed linux-headers'; custom kernel -> its matching '*-headers' package."
  fi
  log "kernel build dir present: ${KBUILD}"
  if ls /sys/class/powercap/intel-rapl-mmio:* >/dev/null 2>&1; then
    log "MMIO-RAPL power-cap interface present"
  else
    warn "intel-rapl-mmio not found -- the CPU power cap may not be settable on this kernel/BIOS (legion control still installs)"
  fi
  have sudo || die "sudo not found"
}

deps() {
  step "Installing dependencies"
  local pkgs="base-devel git lm_sensors stress-ng"
  $SUDO pacman -S --needed --noconfirm $pkgs 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "pacman failed to install: $pkgs"
  have make || die "make not found after installing base-devel"
  have git  || die "git not found after install"
  log "dependencies present"
}

get_source() {
  step "Fetching legion driver source"
  if [ "$FORCE" = 1 ] && [ -d "$REPO_DIR" ]; then
    log "force: removing existing $REPO_DIR for a clean clone"
    rm -rf "$REPO_DIR" 2>/dev/null || $SUDO rm -rf "$REPO_DIR" || die "could not remove $REPO_DIR"
  fi
  if [ -d "$REPO_DIR/.git" ]; then
    log "skip: source already present at $REPO_DIR"
    return 0
  fi
  [ -e "$REPO_DIR" ] && die "$REPO_DIR exists but is not a git repo; move it aside or set LEGION_REPO_DIR"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>&1 | tee -a "$LOGFILE"
  { [ "${PIPESTATUS[0]}" -eq 0 ] && [ -d "$REPO_DIR/.git" ]; } || die "git clone failed (network? $REPO_URL)"
  log "cloned $REPO_URL -> $REPO_DIR"
}

patch_source() {
  step "Patching legion driver to bind VPC2004 (the author's TODO; PNP0C09 is owned by acpi-ec)"
  local f="$REPO_DIR/kernel_module/legion-laptop.c"
  [ -f "$f" ] || die "legion-laptop.c not found at $f"
  if awk '/legion_device_ids\[\] = \{/{b=1} b&&/VPC2004/{ok=1} b&&/\};/{b=0} END{exit !ok}' "$f"; then
    log "skip: already patched to VPC2004"
    return 0
  fi
  awk '
    /static const struct acpi_device_id legion_device_ids\[\] = \{/ { inblk=1 }
    inblk && /\};/ { inblk=0 }
    inblk && /"PNP0C09"/ && !done { sub(/"PNP0C09"/, "\"VPC2004\""); done=1 }
    { print }
  ' "$f" > "$f.tmp" || die "patch (awk) failed"
  if awk '/legion_device_ids\[\] = \{/{b=1} b&&/VPC2004/{ok=1} b&&/\};/{b=0} END{exit !ok}' "$f.tmp"; then
    mv "$f.tmp" "$f" || die "could not write patched $f"
    log "patched: legion_device_ids now matches VPC2004"
  else
    rm -f "$f.tmp"
    die "patch did not take -- upstream source layout may have changed; inspect $f"
  fi
}

build_module() {
  step "Building legion-laptop.ko for ${KREL}"
  # earlier root builds (sudo) leave root-owned .o/.cmd artifacts a user build can't overwrite;
  # normalize ownership of the module dir, then clean stale artifacts before compiling.
  $SUDO chown -R "$(id -u):$(id -g)" "$REPO_DIR/kernel_module" 2>/dev/null || true
  make -C "$KBUILD" M="$REPO_DIR/kernel_module" clean >/dev/null 2>&1 || true
  make -C "$KBUILD" M="$REPO_DIR/kernel_module" modules 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "module build failed (see $LOGFILE)"
  [ -f "$REPO_DIR/kernel_module/legion-laptop.ko" ] || die "build reported success but legion-laptop.ko is missing"
  log "built legion-laptop.ko ($(du -h "$REPO_DIR/kernel_module/legion-laptop.ko" 2>/dev/null | cut -f1))"
}

install_module() {
  step "Installing legion-laptop.ko + depmod"
  local dst="/lib/modules/${KREL}/kernel/drivers/platform/x86"
  $SUDO install -Dm644 "$REPO_DIR/kernel_module/legion-laptop.ko" "$dst/legion-laptop.ko" || die "install of module failed"
  $SUDO depmod -a "$KREL" || die "depmod failed"
  log "installed -> $dst/legion-laptop.ko"
}

write_configs() {
  step "Writing module config (autoload, options, blacklists)"
  write_file /etc/modprobe.d/legion-laptop.conf "options legion-laptop enable_platformprofile=true"
  # only gamezone conflicts with legion's GameZone WMI GUID; keep _other/_events so Fn hotkeys work
  write_file /etc/modprobe.d/blacklist-lenovo-wmi.conf "blacklist lenovo_wmi_gamezone"
  write_file /etc/modprobe.d/blacklist-ideapad.conf "blacklist ideapad_laptop"
  write_file /etc/modules-load.d/legion-laptop.conf "$(printf '%s\n' 'legion-laptop' 'coretemp')"
}

install_tool() {
  step "Installing power governor -> $TOOL_DST"
  $SUDO tee "$TOOL_DST" >/dev/null <<'__LEGION_POWERCAP_TOOL__'
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
#
set -uo pipefail

# ---- help works without root ----
case "${1:-}" in -h|--help) sed -n '2,30p' "$0"; exit 0 ;; esac

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
      'BEGIN{ d=b-a; if(d<0) d+=m; printf "%.1f", d/(w*1000000) }')"
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
    { echo "MMIO_PATH=$m"; echo "ORIG_PL1=$cur0"; echo "ORIG_PL2=$cur1"; } > "$ORIG_FILE"
    chown "$real_user" "$ORIG_FILE" 2>/dev/null || true
    log INFO "saved original limits to $ORIG_FILE (PL1=$(uw2w "$cur0") W PL2=$(uw2w "$cur1") W)"
  fi
  # shellcheck disable=SC1090
  . "$ORIG_FILE"

  if [ "$DO_LOAD" = 1 ]; then
    log STEP "Baseline (limits forced to original $(uw2w "$ORIG_PL1") W for a fair before/after)"
    echo "$ORIG_PL1" > "$m/constraint_0_power_limit_uw" 2>/dev/null
    echo "$ORIG_PL2" > "$m/constraint_1_power_limit_uw" 2>/dev/null
    measure "$LOAD_SECS" "before" "$m"
    local base_mhz="$MEAS_MHZ" base_w="$MEAS_W"
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
  local m p1 p2
  if [ -f "$ORIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ORIG_FILE"; m="$MMIO_PATH"; p1="$ORIG_PL1"; p2="$ORIG_PL2"
  else
    m="$(find_mmio_pkg)" || die "no mmio domain"; p1=30000000; p2=30000000
    log WARN "no saved originals; restoring to 30 W default"
  fi
  echo "$p1" > "$m/constraint_0_power_limit_uw" 2>/dev/null
  echo "$p2" > "$m/constraint_1_power_limit_uw" 2>/dev/null
  log OK "restored PL1=$(uw2w "$p1") W  PL2=$(uw2w "$p2") W"
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

  local last_key="" eff1=0 eff2=0 cur1=0 throttled=0 mode ac temp t1 t2
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
      echo "$(w2uw "$SAFE_PL1")" > "$m/constraint_0_power_limit_uw" 2>/dev/null
      log WARN "CPU temp unreadable -> holding PL1 at safe ${SAFE_PL1}W"
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
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
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
__LEGION_POWERCAP_TOOL__
  $SUDO chmod 0755 "$TOOL_DST" || die "chmod of $TOOL_DST failed"
  bash -n "$TOOL_DST" || die "installed governor failed its own syntax check"
  log "installed + syntax-checked $TOOL_DST"
}

install_service() {
  step "Installing + enabling governor service ($SERVICE_NAME)"
  write_file "$SERVICE_DST" "$(cat <<EOF
[Unit]
Description=Legion Pro 7 16IAX10H power governor (follows Fn-Q mode + thermal guard)
After=multi-user.target

[Service]
Type=simple
ExecStart=$TOOL_DST --daemon
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
)"
  $SUDO systemctl daemon-reload || die "systemctl daemon-reload failed"
  if $SUDO systemctl is-enabled "$OLD_ONESHOT" >/dev/null 2>&1; then
    $SUDO systemctl disable --now "$OLD_ONESHOT" >/dev/null 2>&1 || true
    log "retired old one-shot $OLD_ONESHOT"
  fi
  $SUDO systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || die "could not enable $SERVICE_NAME"
  log "enabled $SERVICE_NAME (starts at boot)"
}

activate() {
  if [ "$SKIP_ACTIVATE" = 1 ]; then
    step "Skipping runtime activation (--skip-activate) -- everything applies at next boot"
    return 0
  fi
  step "Activating now (best effort; reboot is the clean confirmation)"
  $SUDO modprobe coretemp 2>/dev/null || true
  if lsmod | grep -q '^ideapad_laptop'; then
    if $SUDO modprobe -r ideapad_laptop 2>/dev/null; then
      log "unloaded ideapad_laptop (frees VPC2004; clears its false wifi rfkill)"
    else
      warn "could not unload ideapad_laptop now (it is blacklisted from next boot regardless)"
    fi
  fi
  if lsmod | grep -q '^lenovo_wmi_gamezone'; then
    $SUDO modprobe -r lenovo_wmi_gamezone 2>/dev/null || warn "could not unload lenovo_wmi_gamezone now (blacklisted from next boot)"
  fi
  $SUDO modprobe -r legion_laptop 2>/dev/null || true
  $SUDO modprobe legion-laptop 2>/dev/null || warn "modprobe legion-laptop failed now (will load at boot)"
  sleep 1
  if [ -d /sys/bus/platform/drivers/legion/VPC2004:00 ]; then
    log "legion bound to VPC2004:00"
  else
    warn "legion did not bind now -- a reboot (with ideapad blacklisted) binds it cleanly"
  fi
  $SUDO rfkill unblock all 2>/dev/null || true
  if $SUDO systemctl restart "$SERVICE_NAME" 2>/dev/null; then
    sleep 1
    if $SUDO systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
      log "governor service running"
    else
      warn "governor not active yet -- check: journalctl -u $SERVICE_NAME"
    fi
  else
    warn "could not start governor now; it will start at boot"
  fi
}

# ---- verification check helpers (count into VPASS/VFAIL/VWARN) ----
VPASS=0; VFAIL=0; VWARN=0
vok()   { VPASS=$((VPASS+1)); printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; _logf "    [ ok ] $*"; }
vfail() { VFAIL=$((VFAIL+1)); printf '    \033[0;31m[FAIL]\033[0m %s\n' "$*"; _logf "    [FAIL] $*"; }
vwarn() { VWARN=$((VWARN+1)); printf '    \033[1;33m[warn]\033[0m %s\n' "$*"; _logf "    [warn] $*"; }

# expected sustained PL1 (W) for a mode name, matching the governor defaults
mode_pl1() { case "$1" in quiet) echo 45 ;; performance|custom) echo 130 ;; *) echo 90 ;; esac; }

# package temperature (coretemp "Package id 0"), or 0 if unavailable
pkg_temp_c() {
  local h lf raw
  for h in /sys/class/hwmon/*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "coretemp" ] || continue
    for lf in "$h"/temp*_label; do
      [ "$(cat "$lf" 2>/dev/null)" = "Package id 0" ] || continue
      raw="$(cat "${lf%_label}_input" 2>/dev/null)"; case "$raw" in ''|*[!0-9]*) ;; *) echo $((raw/1000)); return ;; esac
    done
  done
  echo 0
}

# read-only post-install / post-reboot verification (no sudo needed)
do_verify() {
  VPASS=0; VFAIL=0; VWARN=0
  step "Verification (read-only)"

  local prod bios prof="" pm mmio="" d MODS
  prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  case "$bios" in Q7CN*|SMCN*) vok "machine: ${prod} / ${bios}" ;; *) vwarn "machine: ${prod} / ${bios} (not Q7CN/SMCN)" ;; esac

  # NOTE: read lsmod once into a var and match with a here-string. Piping into
  # 'grep -q' would let grep close the pipe early, SIGPIPE lsmod, and (under
  # 'set -o pipefail') report failure even when the module IS present.
  MODS="$(lsmod 2>/dev/null)"
  grep -q '^legion_laptop[[:space:]]'      <<<"$MODS" && vok "legion_laptop module loaded"            || vfail "legion_laptop module NOT loaded"
  [ -d /sys/bus/platform/drivers/legion/VPC2004:00 ]  && vok "legion bound to VPC2004:00"              || vfail "legion NOT bound to VPC2004:00"
  grep -q '^ideapad_laptop[[:space:]]'     <<<"$MODS" && vfail "ideapad_laptop is loaded (blacklist not effective)" || vok "ideapad_laptop not loaded (blacklist OK)"
  grep -q '^lenovo_wmi_gamezone[[:space:]]' <<<"$MODS" && vfail "lenovo_wmi_gamezone loaded (would steal the GameZone WMI GUID)" || vok "lenovo_wmi_gamezone not loaded (blacklist OK)"

  prof="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || true)"
  if [ -z "$prof" ]; then
    for d in /sys/class/platform-profile/*/profile; do [ -r "$d" ] && { prof="$(cat "$d" 2>/dev/null || true)"; break; }; done
  fi
  [ -n "$prof" ] && vok "platform_profile present: $prof" || vfail "platform_profile missing (Fn-Q interface not registered)"
  pm="$(cat /sys/bus/platform/devices/VPC2004:00/powermode 2>/dev/null || true)"
  [ -n "$pm" ] && vok "legion powermode readable: $pm" || vwarn "legion powermode not readable"

  for d in /sys/class/powercap/intel-rapl-mmio:*; do [ "$(cat "$d/name" 2>/dev/null)" = "package-0" ] && { mmio="$d"; break; }; done
  [ -n "$mmio" ] && vok "MMIO-RAPL package domain present: $(basename "$mmio")" || vfail "MMIO-RAPL package-0 domain missing"
  [ "$(pkg_temp_c)" -gt 0 ] 2>/dev/null && vok "coretemp sensor present (thermal guard)" || vwarn "coretemp sensor missing (guard uses EC temp)"

  [ -x "$TOOL_DST" ] && vok "governor tool installed: $TOOL_DST" || vfail "governor tool missing: $TOOL_DST"
  systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1 && vok "service enabled (starts at boot)" || vfail "service NOT enabled"
  systemctl is-active  "$SERVICE_NAME" >/dev/null 2>&1 && vok "service active now" || vfail "service NOT active"

  for d in /etc/modprobe.d/legion-laptop.conf /etc/modprobe.d/blacklist-lenovo-wmi.conf \
           /etc/modprobe.d/blacklist-ideapad.conf /etc/modules-load.d/legion-laptop.conf "$SERVICE_DST"; do
    [ -f "$d" ] && vok "config present: $d" || vfail "config missing: $d"
  done

  # functional: does the live MMIO PL1 match what the current Fn-Q mode should produce?
  if [ -n "$mmio" ]; then
    local mode_name pl1 exp ac temp
    case "$prof" in
      low-power|quiet|cool) mode_name=quiet ;;
      performance|max-power) mode_name=performance ;;
      *) mode_name=balanced ;;
    esac
    pl1="$(awk '{printf "%.0f", $1/1000000}' "$mmio/constraint_0_power_limit_uw" 2>/dev/null || echo 0)"
    exp="$(mode_pl1 "$mode_name")"
    ac=1; for d in /sys/class/power_supply/*; do [ "$(cat "$d/type" 2>/dev/null)" = "Mains" ] && { ac="$(cat "$d/online" 2>/dev/null || echo 1)"; break; }; done
    [ "$ac" = 0 ] && [ "$exp" -gt 90 ] && exp=90
    temp="$(pkg_temp_c)"
    if [ "$pl1" = "$exp" ]; then
      vok "governor functional: mode=${mode_name}$([ "$ac" = 0 ] && echo ' (battery)') -> PL1=${pl1}W (matches)"
    elif [ "$pl1" -lt "$exp" ] && [ "$temp" -ge 94 ]; then
      vok "governor functional: PL1=${pl1}W (< ${exp}W) but CPU at ${temp}C -- thermal guard active (expected)"
    elif [ "$pl1" -gt 30 ]; then
      vwarn "PL1=${pl1}W != mode=${mode_name} expected ${exp}W (allow ~3s after a mode change; see journalctl -u $SERVICE_NAME)"
    else
      vfail "PL1=${pl1}W -- governor not applying limits (still at the stock 30W cap?)"
    fi
  fi

  step "Result: ${VPASS} passed, ${VFAIL} failed, ${VWARN} warning(s)"
  if [ "$VFAIL" -eq 0 ]; then
    log "Everything critical checks out -- the setup is installed and running correctly."
    return 0
  fi
  err "${VFAIL} critical check(s) failed (see [FAIL] lines). If you just installed, REBOOT then re-run: ./$(basename "$0") --verify"
  return 1
}

summary() {
  step "Done"
  log "Fn-Q modes -> CPU power limit:  quiet=45W  balanced=90W  performance=130W (~128W chassis ceiling)"
  log "Thermal guard: throttle >=96C, recover <=88C.  On battery: capped to 90W."
  log "Tool:    sudo $TOOL_DST  [ --status | --sweep | --daemon | --pl1 N --pl2 N | --restore ]"
  log "Service: systemctl status ${SERVICE_NAME%.service}   (logs: journalctl -u $SERVICE_NAME)"
  log "Install log: $LOGFILE"
  warn "ideapad_laptop is blacklisted (frees VPC2004 + fixes the wifi rfkill); you lose ideapad conservation-mode/extra keys."
  log "REBOOT recommended -- then confirm everything with:  ./$(basename "$0") --verify"
}

# ============================ main ============================
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)          FORCE=1 ;;
      --skip-activate)  SKIP_ACTIVATE=1 ;;
      --verify|--test)  ACTION=verify ;;
      -h|--help)        sed -n '2,33p' "$0"; exit 0 ;;
      *)                die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

ACTION="install"
parse_args "$@"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# verify-only mode: run the read-only checks and exit with their status (no install)
if [ "$ACTION" = "verify" ]; then
  do_verify
  exit $?
fi

step "Build_16iax10h_power.sh  (user=$(id -un), force=$FORCE, kernel=$KREL)"
preflight
deps
get_source
patch_source
build_module
install_module
write_configs
install_tool
install_service
activate
do_verify || true
summary
exit 0
