#!/usr/bin/env bash
#
# Build_16iax10h_power.sh
# One-shot, idempotent installer for the Lenovo Legion Pro 7 16IAX10H (Q7CN, EC IT5508)
# power / fan / Fn-Q-mode solution on a fresh Arch Linux install.
#
# It performs, with dependency checks, error checking, logging and skip-on-done:
#   1. preflight  - verify model (product 83F5 / BIOS Q7CN|SMCN) and kernel build support
#   2. deps       - pacman -S --needed base-devel git lm_sensors stress-ng dkms
#   3. source     - clone gluceri/legion-pro-7-16iax10h-linux
#   4. patch      - bind legion-laptop to VPC2004 (instead of PNP0C09, which acpi-ec owns)
#                   + add battery conservation_mode (caps charging; DSDT-verified SBMC 0x03/0x05)
#                   + a legion-conservation.service that caps charging at boot (toggle anytime)
#   5. dkms       - register legion-laptop with DKMS + build/install for the running kernel
#                   (auto-rebuilds for every future kernel, so kernel changes never break it)
#   6. configs    - modprobe options (enable_platformprofile), blacklists (lenovo-wmi, ideapad),
#                   autoload (legion-laptop + coretemp)
#   7. tool       - install the power governor to /usr/local/bin/legion-powercap
#   8. service    - install + enable legion-powercapd.service (follows Fn-Q mode + thermal guard)
#   9. activate   - bind legion + start the governor now (no reboot needed, best effort)
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
CONS_SERVICE_NAME="legion-conservation.service"
CONS_SERVICE_DST="/etc/systemd/system/${CONS_SERVICE_NAME}"
LEGION_SYSFS="/sys/bus/platform/devices/VPC2004:00"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd || echo "$PWD")"
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
  # DKMS needs the kernel headers/build tree to compile the module for this kernel
  if [ ! -d "$KBUILD" ]; then
    die "no kernel headers for ${KREL} (missing ${KBUILD}); DKMS needs them. Install and re-run: stock kernel -> 'sudo pacman -S --needed linux-headers'; custom kernel -> its matching '*-headers' package."
  fi
  log "kernel headers present (DKMS will build against ${KBUILD})"
  if ls /sys/class/powercap/intel-rapl-mmio:* >/dev/null 2>&1; then
    log "MMIO-RAPL power-cap interface present"
  else
    warn "intel-rapl-mmio not found -- the CPU power cap may not be settable on this kernel/BIOS (legion control still installs)"
  fi
  have sudo || die "sudo not found"
}

deps() {
  step "Installing dependencies"
  local pkgs="base-devel git lm_sensors stress-ng dkms"
  $SUDO pacman -S --needed --noconfirm $pkgs 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "pacman failed to install: $pkgs"
  have make || die "make not found after installing base-devel"
  have git  || die "git not found after install"
  have dkms || die "dkms not found after install"
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

# Add a battery conservation_mode sysfs to the legion driver. The DSDT's SBMC
# method takes 0x03 (BTSM=1, cap charging ~60-80%) / 0x05 (BTSM=0, off); status
# is GBMD & 0x20. The driver already has the SBMC/GBMD plumbing for rapidcharge
# but addresses them as "VPC0.SBMC" -- wrong once bound to VPC2004 (== VPC0), so
# we also fix the path (which revives rapidcharge). Verified against this DSDT.
patch_conservation() {
  step "Adding battery conservation_mode to the legion driver (caps charging; revives rapidcharge)"
  local f="$REPO_DIR/kernel_module/legion-laptop.c"
  local blk="$SCRIPT_DIR/patches/legion-conservation-block.c"
  [ -f "$f" ] || die "legion-laptop.c not found at $f"
  if grep -q 'conservation_mode' "$f"; then
    log "skip: conservation_mode already present"
    return 0
  fi
  [ -f "$blk" ] || die "conservation patch block missing at $blk (repo incomplete?)"
  # 1) correct the SBMC/GBMD relative path (methods are direct children of VPC2004=VPC0)
  sed -i 's/"VPC0\.SBMC"/"SBMC"/; s/"VPC0\.GBMD"/"GBMD"/' "$f"
  # 2) insert the conservation helpers + sysfs attr (mirrors rapidcharge) after its DEVICE_ATTR_RW
  sed -i "/^static DEVICE_ATTR_RW(rapidcharge);\$/r $blk" "$f"
  # 3) register the attribute in the same group as rapidcharge (flush-left is fine; C ignores indent)
  sed -i '/&dev_attr_rapidcharge\.attr,/a &dev_attr_conservation_mode.attr,' "$f"
  { grep -q 'DEVICE_ATTR_RW(conservation_mode)' "$f" && grep -q 'dev_attr_conservation_mode.attr' "$f" \
      && ! grep -q '"VPC0\.SBMC"' "$f"; } \
    || die "conservation patch did not fully apply -- inspect $f"
  log "patched: conservation_mode added; SBMC/GBMD path fixed"
}

DKMS_PKG="LenovoLegionLinux"
DKMS_VER="0.1.0"
DKMS_SRC="/usr/src/${DKMS_PKG}-${DKMS_VER}"

dkms_install() {
  step "Installing legion-laptop via DKMS (builds for ${KREL} + auto-rebuilds on future kernels)"

  # stage ONLY the source files into /usr/src (no .o/.ko/.cmd artifacts) so DKMS builds clean.
  # legion-laptop.c has no local includes; the Makefile only builds legion-laptop.o.
  $SUDO rm -rf "$DKMS_SRC"
  $SUDO install -d "$DKMS_SRC"
  local sf
  for sf in legion-laptop.c Makefile dkms.conf; do
    [ -f "$REPO_DIR/kernel_module/$sf" ] || die "missing source file: kernel_module/$sf"
    $SUDO install -m644 "$REPO_DIR/kernel_module/$sf" "$DKMS_SRC/$sf" || die "could not stage $sf"
  done
  # confirm the staged source carries the VPC2004 device-id (the quoted form -> the id table, not a comment)
  grep -q '"VPC2004"' "$DKMS_SRC/legion-laptop.c" || die "staged source is not VPC2004-patched"

  # clear any prior registration, then add/build/install for the running kernel
  $SUDO dkms remove -m "$DKMS_PKG" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
  $SUDO dkms add -m "$DKMS_PKG" -v "$DKMS_VER" 2>&1 | tee -a "$LOGFILE" || true
  # verify registration regardless of 'add' exit code (dkms add returns non-zero if already added)
  [ -n "$($SUDO dkms status -m "$DKMS_PKG" -v "$DKMS_VER" 2>/dev/null)" ] \
    || die "dkms add did not register $DKMS_PKG/$DKMS_VER (see $LOGFILE)"
  $SUDO dkms build -m "$DKMS_PKG" -v "$DKMS_VER" -k "$KREL" --force 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "dkms build failed for $KREL (see $LOGFILE)"
  $SUDO dkms install -m "$DKMS_PKG" -v "$DKMS_VER" -k "$KREL" --force 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "dkms install failed for $KREL (see $LOGFILE)"
  $SUDO depmod -a "$KREL"

  modinfo -k "$KREL" legion-laptop >/dev/null 2>&1 \
    || die "DKMS reported success but 'modinfo -k $KREL legion-laptop' still fails"
  log "DKMS OK -> $($SUDO dkms status -m "$DKMS_PKG" -v "$DKMS_VER" 2>/dev/null | head -1)"
  # AUTOINSTALL=yes: a kernel/headers install normally triggers the dkms pacman hook to rebuild;
  # custom-kernel rebuilds usually install the -headers package which does trigger it, but to be
  # safe always confirm afterward with:  ./Build_16iax10h_power.sh --verify
  log "registered with DKMS (AUTOINSTALL=yes); after any kernel rebuild, run --verify to confirm"
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
  # single source of truth: install the repo's raise-power-cap.sh verbatim.
  # (this used to be an embedded copy of the script, which silently drifted
  # from the repo file whenever one of them was edited)
  local src="$SCRIPT_DIR/raise-power-cap.sh"
  [ -f "$src" ] || die "governor source not found at $src (run from the repo checkout)"
  bash -n "$src" || die "raise-power-cap.sh failed its syntax check; not installing"
  $SUDO install -m0755 "$src" "$TOOL_DST" || die "could not install $TOOL_DST"
  log "installed + syntax-checked $TOOL_DST (from $src)"
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

install_conservation_service() {
  step "Installing battery conservation service ($CONS_SERVICE_NAME)"
  # oneshot: caps charging at boot (echo 1). Stopping it (or 'echo 0') charges to 100%.
  write_file "$CONS_SERVICE_DST" "$(cat <<EOF
[Unit]
Description=Legion battery conservation mode (limits max charge to protect the cell)
After=multi-user.target
ConditionPathExists=$LEGION_SYSFS/conservation_mode

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 1 > $LEGION_SYSFS/conservation_mode'
ExecStop=/bin/sh -c 'echo 0 > $LEGION_SYSFS/conservation_mode'

[Install]
WantedBy=multi-user.target
EOF
)"
  $SUDO systemctl daemon-reload || die "systemctl daemon-reload failed"
  if [ "${LEGION_CONSERVATION:-1}" = 0 ]; then
    $SUDO systemctl disable "$CONS_SERVICE_NAME" >/dev/null 2>&1 || true
    log "conservation installed but left OFF (LEGION_CONSERVATION=0): enable with 'systemctl enable --now $CONS_SERVICE_NAME'"
  else
    $SUDO systemctl enable "$CONS_SERVICE_NAME" >/dev/null 2>&1 || die "could not enable $CONS_SERVICE_NAME"
    log "enabled $CONS_SERVICE_NAME (charging capped at boot)"
  fi
}

activate() {
  if [ "$SKIP_ACTIVATE" = 1 ]; then
    step "Skipping runtime activation (--skip-activate) -- everything applies at next boot"
    return 0
  fi
  step "Activating now (best effort; reboot is the clean confirmation)"
  $SUDO modprobe coretemp 2>/dev/null || true
  # capture lsmod once: 'lsmod | grep -q' under pipefail can die by SIGPIPE and
  # falsely report "not loaded" (same hazard do_verify documents and avoids)
  local mods; mods="$(lsmod 2>/dev/null)"
  if grep -q '^ideapad_laptop' <<<"$mods"; then
    if $SUDO modprobe -r ideapad_laptop 2>/dev/null; then
      log "unloaded ideapad_laptop (frees VPC2004; clears its false wifi rfkill)"
    else
      warn "could not unload ideapad_laptop now (it is blacklisted from next boot regardless)"
    fi
  fi
  if grep -q '^lenovo_wmi_gamezone' <<<"$mods"; then
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
  if [ -e "$LEGION_SYSFS/conservation_mode" ] && [ "${LEGION_CONSERVATION:-1}" != 0 ]; then
    echo 1 | $SUDO tee "$LEGION_SYSFS/conservation_mode" >/dev/null 2>&1 \
      && log "battery conservation ON now (charging capped)" \
      || warn "could not set conservation now (applies at boot via $CONS_SERVICE_NAME)"
  fi
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

  local prod bios prof="" pm mmio="" d MODS cm
  prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  case "$bios" in Q7CN*|SMCN*) vok "machine: ${prod} / ${bios}" ;; *) vwarn "machine: ${prod} / ${bios} (not Q7CN/SMCN)" ;; esac

  # NOTE: read lsmod once into a var and match with a here-string. Piping into
  # 'grep -q' would let grep close the pipe early, SIGPIPE lsmod, and (under
  # 'set -o pipefail') report failure even when the module IS present.
  # is the module even built for the RUNNING kernel? (catches "kernel rebuilt, module not rebuilt")
  if modinfo -k "$(uname -r)" legion-laptop >/dev/null 2>&1; then
    vok "legion-laptop built for the running kernel ($(uname -r))"
  else
    vfail "legion-laptop NOT built for $(uname -r) -- run: sudo dkms autoinstall  (or re-run this installer)"
  fi
  DKMS_STAT="$(dkms status -m LenovoLegionLinux 2>/dev/null || true)"
  if [ -n "$DKMS_STAT" ]; then
    vok "DKMS registered (auto-rebuilds on kernel changes): $(head -1 <<<"$DKMS_STAT")"
  else
    vwarn "legion not registered with DKMS -- it won't auto-rebuild on kernel updates (re-run the installer to fix)"
  fi

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

  # battery conservation (cap charging) -- driver patch + service
  if [ -e "$LEGION_SYSFS/conservation_mode" ]; then
    cm="$(cat "$LEGION_SYSFS/conservation_mode" 2>/dev/null || echo '?')"
    vok "battery conservation_mode present (now=${cm}; 1=charging capped)"
  else
    vwarn "conservation_mode sysfs missing (driver not rebuilt with the patch? re-run the installer)"
  fi
  systemctl is-enabled "$CONS_SERVICE_NAME" >/dev/null 2>&1 && vok "conservation service enabled (caps at boot)" || vwarn "conservation service not enabled"

  # functional: does the live MMIO PL1 match what the current Fn-Q mode should produce?
  if [ -n "$mmio" ]; then
    local mode_name pl1 exp ac temp fwmax
    case "$prof" in
      low-power|quiet|cool) mode_name=quiet ;;
      performance|max-power) mode_name=performance ;;
      *) mode_name=balanced ;;
    esac
    pl1="$(awk '{printf "%.0f", $1/1000000}' "$mmio/constraint_0_power_limit_uw" 2>/dev/null || echo 0)"
    exp="$(mode_pl1 "$mode_name")"
    # AC vs battery: the governor caps PL1 to the battery ceiling (90W) off-charger
    ac=1; for d in /sys/class/power_supply/*; do [ "$(cat "$d/type" 2>/dev/null)" = "Mains" ] && { ac="$(cat "$d/online" 2>/dev/null || echo 1)"; break; }; done
    [ "$ac" = 0 ] && [ "$exp" -gt 90 ] && exp=90
    # On BATTERY only, the BIOS hard-clamps MMIO PL1 to constraint_0_max_power_uw
    # (~55W); a request above that silently clamps, so the live value can be < exp.
    # On AC that field still reads ~55W but is NOT enforced (full watts apply), so we
    # must NOT clamp the expectation on AC -- doing so caused a false warning at 130W.
    fwmax="$(awk '{printf "%.0f", $1/1000000}' "$mmio/constraint_0_max_power_uw" 2>/dev/null || echo 0)"
    [ "$ac" = 0 ] && [ "${fwmax:-0}" -gt 0 ] && [ "$exp" -gt "$fwmax" ] && exp="$fwmax"
    temp="$(pkg_temp_c)"
    if [ "$pl1" = "$exp" ]; then
      vok "governor functional: mode=${mode_name}$([ "$ac" = 0 ] && echo ' (battery)') -> PL1=${pl1}W (matches$([ "$ac" = 0 ] && echo ', firmware-clamped'))"
    elif [ "$pl1" -gt "$exp" ] && [ "$ac" = 1 ]; then
      # on AC the live PL1 can EXCEED the nominal mode floor (boost / firmware headroom) -- that's fine
      vok "governor functional: mode=${mode_name} (AC) -> PL1=${pl1}W (>= ${exp}W target; full power on AC)"
    elif [ "$pl1" -lt "$exp" ] && [ "$temp" -ge 94 ]; then
      vok "governor functional: PL1=${pl1}W (< ${exp}W) but CPU at ${temp}C -- thermal guard active (expected)"
    elif [ "$ac" = 0 ] && [ "$pl1" -gt 30 ] && [ "$pl1" -le "${fwmax:-55}" ]; then
      vok "governor functional: PL1=${pl1}W on battery (BIOS clamps to ~${fwmax}W off-charger; full ${mode_name} watts apply on AC)"
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
  log "DKMS built legion for ${KREL}; it auto-rebuilds on kernel installs. Other installed kernels"
  log "  (linux/linux-zen) get it when their headers install, or run 'sudo dkms autoinstall'."
  log "Battery: conservation_mode caps charging (~60-80%) to protect the cell (on by default)."
  log "  charge to 100% once:  echo 0 | sudo tee $LEGION_SYSFS/conservation_mode"
  log "  cap again:            echo 1 | sudo tee $LEGION_SYSFS/conservation_mode"
  log "  keep 100% across reboots: sudo systemctl disable --now $CONS_SERVICE_NAME"
  warn "ideapad_laptop is blacklisted (frees VPC2004 + fixes the wifi rfkill); you lose a few extra Fn keys (battery conservation is now provided by the legion driver patch)."
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
patch_conservation
dkms_install
write_configs
install_tool
install_service
install_conservation_service
activate
do_verify || true
summary
exit 0
