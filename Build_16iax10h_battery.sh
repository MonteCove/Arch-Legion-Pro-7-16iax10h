#!/usr/bin/env bash
#
# Build_16iax10h_battery.sh
# One-shot, idempotent battery-efficiency installer for the Lenovo Legion Pro 7
# 16IAX10H on Arch Linux. Companion to Build_16iax10h_power.sh (RAPL governor);
# this one fixes what a live audit found draining the battery vs Windows:
#
#   - NO power-management daemon existed: the ACPI platform profile stayed on
#     'performance' and the CPU EPP on 'balance_performance' even on battery,
#     PCIe ASPM on [default], Wake-on-LAN armed, NMI watchdog on.
#   - The SDDM greeter's leftover Xorg held /dev/nvidia0 open forever, pinning
#     the RTX 5080 in P8 (~5-10 W idle) instead of D3cold (~0 W).
#
# Steps (dependency checks, error checking, logging, skip-on-done):
#   1. preflight - verify model; refuse if power-profiles-daemon/tuned conflict
#   2. deps      - pacman -S --needed tlp powertop
#   3. configs   - /etc/tlp.d/00-16iax10h-battery.conf  (from battery/)
#                  /etc/X11/xorg.conf.d/10-igpu-only.conf (from battery/)
#   4. services  - enable+start tlp.service; mask systemd-rfkill (TLP owns radios)
#   5. dispatch  - AC/battery dispatcher: OLED 60 Hz + Frigate NVR stopped on
#                  battery, 240 Hz + NVR back on AC (udev + boot + session hook)
#   6. cleanup   - drop stale 99-legion-ppd-restart.rules (daemon not installed);
#                  bluetooth AutoEnable=false (radio powers on per-use, not at boot)
#   7. verify    - show EPP / platform profile / ASPM / dGPU power state
#
# The dGPU only reaches D3cold once the old greeter Xorg is gone: reboot, or run
# with --release-dgpu-now (kills that Xorg; the screen may blink to the login VT
# for a moment — switch back with Ctrl+Alt+F1 if it stays there).
#
# Usage:
#   ./Build_16iax10h_battery.sh                    # full install (safe to re-run)
#   ./Build_16iax10h_battery.sh --verify           # read-only check; no sudo
#   ./Build_16iax10h_battery.sh --release-dgpu-now # install + free the dGPU now
#   ./Build_16iax10h_battery.sh --psr-check        # one-time root read of the
#                                                  # i915 PSR/FBC debugfs status
#
# Run as your NORMAL user (it uses sudo per-step). Revert: delete the two config
# files, 'sudo systemctl disable --now tlp', 'sudo systemctl unmask systemd-rfkill.service systemd-rfkill.socket'.
#
set -uo pipefail

# ---- help works without sudo ----
case "${1:-}" in -h|--help) sed -n '2,36p' "$0"; exit 0 ;; esac

# ---- must run as the normal user; we elevate per-step with sudo ----
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not as root/sudo (it calls sudo per-step)." >&2
  exit 1
fi
SUDO="sudo"

# ============================ config ============================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd || echo "$PWD")"
TLP_SRC="$SCRIPT_DIR/battery/00-16iax10h-battery.conf"
TLP_DST="/etc/tlp.d/00-16iax10h-battery.conf"
XORG_SRC="$SCRIPT_DIR/battery/10-igpu-only.conf"
XORG_DST="/etc/X11/xorg.conf.d/10-igpu-only.conf"
DGPU_PCI="0000:02:00.0"
EXPECT_PRODUCT="83F5"               # Legion Pro 7 16IAX10H
EXPECT_BIOS_PREFIXES="Q7CN SMCN"

VERIFY_ONLY=0
RELEASE_DGPU=0
PSR_CHECK=0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/legion-battery-install"
LOGFILE="$STATE_DIR/install.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

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
  local prod bios biosok=0 p
  prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  log "product=${prod:-?}  bios=${bios:-?}  kernel=$(uname -r)"
  for p in $EXPECT_BIOS_PREFIXES; do case "$bios" in ${p}*) biosok=1 ;; esac; done
  { [ "$prod" = "$EXPECT_PRODUCT" ] && [ "$biosok" = 1 ]; } \
    || die "this installer is specific to the Legion Pro 7 16IAX10H (product ${EXPECT_PRODUCT}, BIOS ${EXPECT_BIOS_PREFIXES}*). Detected product='${prod}' bios='${bios}'."
  [ -f "$TLP_SRC" ]  || die "missing $TLP_SRC (run from the repo checkout)"
  [ -f "$XORG_SRC" ] || die "missing $XORG_SRC (run from the repo checkout)"
  if pacman -Q power-profiles-daemon >/dev/null 2>&1; then
    die "power-profiles-daemon is installed and conflicts with TLP; remove it first: sudo pacman -R power-profiles-daemon"
  fi
  if pacman -Q tuned tuned-ppd >/dev/null 2>&1; then
    die "tuned is installed and conflicts with TLP; remove it first"
  fi
  have sudo || die "sudo not found"
  log "no conflicting power daemon present"
}

deps() {
  step "Installing dependencies (tlp, powertop)"
  $SUDO pacman -S --needed --noconfirm tlp powertop 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "pacman failed to install tlp powertop"
  have tlp || die "tlp not found after install"
  log "dependencies present"
}

configs() {
  step "Writing configs"
  $SUDO install -d /etc/tlp.d /etc/X11/xorg.conf.d || die "could not create config dirs"
  write_file "$TLP_DST"  "$(cat "$TLP_SRC")"
  write_file "$XORG_DST" "$(cat "$XORG_SRC")"
}

services() {
  step "Enabling TLP service"
  $SUDO systemctl enable --now tlp.service >/dev/null 2>&1 || die "could not enable tlp.service"
  # TLP owns radio state; masking avoids fights over rfkill on boot (TLP FAQ)
  $SUDO systemctl mask systemd-rfkill.service systemd-rfkill.socket >/dev/null 2>&1 || warn "could not mask systemd-rfkill (non-fatal)"
  $SUDO tlp start >/dev/null 2>&1 || warn "tlp start returned an error (settings still apply at next power-source change)"
  log "tlp.service enabled and started"
}

dispatch() {
  step "AC/battery dispatcher (OLED 60 Hz + Frigate NVR off on battery)"
  [ -f "$SCRIPT_DIR/battery/16iax10h-power-dispatch.sh" ] || die "missing battery/16iax10h-power-dispatch.sh (run from the repo checkout)"
  $SUDO install -m0755 "$SCRIPT_DIR/battery/16iax10h-power-dispatch.sh" /usr/local/bin/16iax10h-power-dispatch \
    || die "could not install the dispatcher"
  write_file /etc/systemd/system/16iax10h-power-dispatch.service "$(cat "$SCRIPT_DIR/battery/16iax10h-power-dispatch.service")"
  write_file /etc/udev/rules.d/99-16iax10h-power-dispatch.rules "$(cat "$SCRIPT_DIR/battery/99-16iax10h-power-dispatch.rules")"
  $SUDO systemctl daemon-reload || die "systemctl daemon-reload failed"
  $SUDO systemctl enable 16iax10h-power-dispatch.service >/dev/null 2>&1 || warn "could not enable the dispatcher boot run"
  $SUDO udevadm control --reload-rules || warn "udevadm reload failed -- rule active after reboot"
  # the NVR stack is now started/stopped by the dispatcher, not by dockerd
  if docker inspect frigate >/dev/null 2>&1; then
    docker update --restart=no frigate mosquitto >/dev/null 2>&1 \
      && log "frigate+mosquitto restart policy -> no (dispatcher owns them)" \
      || warn "could not change the docker restart policy (docker down?)"
  else
    log "skip: no frigate container found"
  fi
  $SUDO systemctl start 16iax10h-power-dispatch.service 2>/dev/null || warn "dispatcher first run failed"
  log "dispatcher active: applies now, on every plug/unplug, at boot, at session start"
  # optional dGPU-D3cold toggle (user-level, not enabled by default: it trades
  # away the dGPU-wired HDMI/DP outputs while on — see battery/igpu-session.sh)
  if [ -f "$SCRIPT_DIR/battery/igpu-session.sh" ]; then
    $SUDO install -m0755 "$SCRIPT_DIR/battery/igpu-session.sh" /usr/local/bin/16iax10h-igpu-session \
      && log "installed 16iax10h-igpu-session (on|off|status) -- optional ~5W dGPU-off toggle"
  fi
}

cleanup() {
  step "Cleanups (stale PPD udev rule, bluetooth auto-power)"
  if [ -f /etc/udev/rules.d/99-legion-ppd-restart.rules ]; then
    $SUDO rm -f /etc/udev/rules.d/99-legion-ppd-restart.rules \
      && log "removed 99-legion-ppd-restart.rules (restarted power-profiles-daemon, which is not installed)"
  else
    log "skip: stale ppd udev rule already gone"
  fi
  local btconf=/etc/bluetooth/main.conf
  if [ -f "$btconf" ]; then
    if grep -qE '^[[:space:]]*AutoEnable[[:space:]]*=[[:space:]]*false' "$btconf"; then
      log "skip: bluetooth AutoEnable already false"
    elif grep -qE '^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=' "$btconf"; then
      $SUDO sed -i -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable=false/' "$btconf" \
        && log "bluetooth AutoEnable=false (radio no longer powers on at every boot; enable per-use)"
    else
      printf '\n[Policy]\nAutoEnable=false\n' | $SUDO tee -a "$btconf" >/dev/null \
        && log "bluetooth AutoEnable=false appended to $btconf"
    fi
  else
    log "skip: no $btconf"
  fi
}

psr_check() {
  step "i915 PSR / FBC status (one-time root debugfs read)"
  local d found=0
  for d in /sys/kernel/debug/dri/0000:00:02.0 /sys/kernel/debug/dri/0; do
    $SUDO test -f "$d/i915_edp_psr_status" 2>/dev/null || continue
    found=1
    log "--- $d/i915_edp_psr_status ---"
    $SUDO cat "$d/i915_edp_psr_status" 2>/dev/null | sed -n '1,8p'
    $SUDO test -f "$d/i915_fbc_status" 2>/dev/null && { log "--- fbc ---"; $SUDO cat "$d/i915_fbc_status" 2>/dev/null | sed -n '1,4p'; }
    break
  done
  [ "$found" = 1 ] || warn "psr debugfs not found (kernel layout differs); try: sudo ls /sys/kernel/debug/dri/"
  log "PSR 'Enabled: yes'/SRDENT = panel self-refresh works (good, ~0.5-1 W saved at idle)"
}

release_dgpu() {
  step "Releasing the dGPU (killing the leftover SDDM greeter Xorg)"
  local xpid
  xpid="$(pgrep -f '^/usr/lib/Xorg .*sddm' | head -1)"
  if [ -z "$xpid" ]; then
    log "no greeter Xorg running -- nothing to do"
    return 0
  fi
  log "killing Xorg pid $xpid (screen may blink to the login VT; Ctrl+Alt+F1 to return)"
  $SUDO kill "$xpid" || { warn "could not kill Xorg $xpid"; return 0; }
  sleep 4
  verify_dgpu
}

verify_dgpu() {
  local rs
  rs="$(cat /sys/bus/pci/devices/$DGPU_PCI/power/runtime_status 2>/dev/null || echo unknown)"
  if [ "$rs" = "suspended" ]; then
    log "dGPU runtime_status=suspended -- RTX 5080 is now powering off when idle"
  else
    warn "dGPU runtime_status=$rs -- reaches D3cold only once every holder of /dev/nvidia0 exits (reboot is the sure way; nvidia-smi shows the holders)"
  fi
}

verify() {
  step "Verify (read-only)"
  log "platform_profile : $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo '?')  (battery target: quiet)"
  log "EPP              : $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo '?')  (battery target: power)"
  log "PCIe ASPM policy : $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo '?')  (battery target: powersupersave)"
  log "NMI watchdog     : $(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo '?')  (target: 0)"
  local en ac
  en="$(systemctl is-enabled tlp.service 2>/dev/null)" || true
  ac="$(systemctl is-active tlp.service 2>/dev/null)" || true
  log "tlp.service      : ${en:-missing} / ${ac:-inactive}"
  log "tlp config       : $([ -f "$TLP_DST" ] && echo present || echo MISSING)   xorg iGPU pin: $([ -f "$XORG_DST" ] && echo present || echo MISSING)"
  log "dispatcher       : $([ -x /usr/local/bin/16iax10h-power-dispatch ] && echo present || echo MISSING) (60Hz+NVR-off on battery)"
  verify_dgpu
  log "measure on battery with: sudo powertop  (Overview tab shows the discharge watts)"
}

# ----------------- arg parse -----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --verify)           VERIFY_ONLY=1 ;;
    --release-dgpu-now) RELEASE_DGPU=1 ;;
    --psr-check)        PSR_CHECK=1 ;;
    -h|--help)          sed -n '2,36p' "$0"; exit 0 ;;
    *)                  echo "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

if [ "$VERIFY_ONLY" = 1 ]; then
  verify
  exit 0
fi
if [ "$PSR_CHECK" = 1 ]; then
  psr_check
  exit 0
fi

preflight
deps
configs
services
dispatch
cleanup
[ "$RELEASE_DGPU" = 1 ] && release_dgpu
verify
step "Done"
log "AC behavior is unchanged; unplug to see quiet-profile + EPP=power kick in."
log "For the full dGPU win (D3cold), reboot once (or re-run with --release-dgpu-now)."
