#!/usr/bin/env bash
#
# Build_16iax10h_tweaks.sh
# Idempotent "fixes & features" installer for the Lenovo Legion Pro 7 16IAX10H
# (product 83F5, BIOS Q7CN, EC IT5508).  Complements the two main installers:
#   - Build_16iax10h_audio.sh  (speaker kernel)
#   - Build_16iax10h_power.sh  (legion module + RAPL power governor)
#
# This script applies the post-install hardening / fixes / features found by a
# full hardware-enablement audit of this exact machine.  Every module is
# idempotent, logged, error-checked and skip-on-done.  It is organised as a set
# of named MODULES; with no arguments it runs the default set.
#
# Modules (default set runs all except 'spd5118'):
#   resume-audio   HIGH   re-bind the AW88399 smart-amps after resume (speakers
#                         otherwise go silent after suspend -- DSP firmware CRC fails)
#   resume-power   FIX    re-apply the Intel MMIO-RAPL cap after resume (S3 can
#                         silently drop the cap to the BIOS ~30W default)
#   cpu-governor   TUNE   switch cpupower from 'performance' to 'powersave'
#                         (dynamic HWP; still full turbo under load, gentler on battery)
#   snapshots      SAFETY snapper + snap-pac + grub-btrfs -> bootable Btrfs rollback
#   btrfs-scrub    SAFETY monthly scrub timer on / (catches silent bit-rot)
#   zram           TUNE   grow zram swap toward RAM (headroom for kernel/DKMS builds)
#   suspend-deep   TUNE   pin mem_sleep_default=deep (already active; quirk-proof)
#   video-accel    FEAT   intel-media-driver (iHD) iGPU hardware video decode
#   gpu-offload    FEAT   nvidia-prime -> 'prime-run <app>' for per-app dGPU offload
#   thunderbolt    FEAT   bolt (boltd) for Thunderbolt 4 device authorization
#   firmware       FEAT   fwupd metadata refresh + fwupd-refresh.timer
#   nvidia-powerd  FEAT   NVIDIA Dynamic Boost (auto-reverts if BIOS lacks NVPCF)
#   battery-info   INFO   report battery wear + charge-limit availability (READ-ONLY)
#   spd5118        OPT    blacklist the redundant DIMM temp sensor (silences a benign
#                         resume error; opt-in -- you lose DIMM temp readings)
#
# Two things this script deliberately does NOT do (the audit flagged both as unsafe
# on this EC):  (1) write any battery charge-limit / conservation EC code -- there is
# no verified-safe interface on this model;  (2) write a custom fan curve -- writing
# the pwm tables can crash the EC / stop the fans on Q7CN.
#
# Usage:
#   ./Build_16iax10h_tweaks.sh                 # run the default module set (safe to re-run)
#   ./Build_16iax10h_tweaks.sh --verify        # read-only health check (no sudo needed)
#   ./Build_16iax10h_tweaks.sh --list          # list modules and exit
#   ./Build_16iax10h_tweaks.sh resume-audio cpu-governor   # run only these modules
#   ./Build_16iax10h_tweaks.sh all             # run every module incl. opt-in (spd5118)
#   ./Build_16iax10h_tweaks.sh --force <mods>  # redo even if already applied
#
# Run as your NORMAL user (it calls sudo per-step), not via sudo.
#
set -uo pipefail

# ============================ module registry ============================
ALL_MODULES="resume-audio resume-power cpu-governor snapshots btrfs-scrub zram suspend-deep video-accel gpu-offload thunderbolt firmware nvidia-powerd battery-info spd5118"
DEFAULT_MODULES="resume-audio resume-power cpu-governor snapshots btrfs-scrub zram suspend-deep video-accel gpu-offload thunderbolt firmware nvidia-powerd battery-info"

usage() {
  # print the leading comment block (lines after the shebang, up to the first
  # non-# line), stripping the leading "# " -- edit-proof, no hardcoded range
  awk 'NR>1{ if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

# ---- help works without sudo ----
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# ---- must run as the normal user; we elevate per-step with sudo ----
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not as root/sudo (it calls sudo per-step)." >&2
  exit 1
fi
SUDO="sudo"

# ============================ config ============================
EXPECT_PRODUCT="83F5"               # Legion Pro 7 16IAX10H
EXPECT_BIOS_PREFIXES="Q7CN SMCN"    # Q7CN (Intel) / SMCN (AMD sibling)
KREL="$(uname -r)"

SLEEPDIR="/usr/lib/systemd/system-sleep"
CPUPOWER_CONF="/etc/default/cpupower-service.conf"
ZRAM_CONF="/etc/systemd/zram-generator.conf"
GRUB_DEFAULT="/etc/default/grub"
GRUB_CFG="/boot/grub/grub.cfg"
POWERCAPD="legion-powercapd.service"
RAPL_UW="/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"
AW_DRV="/sys/bus/i2c/drivers/aw88399-hda"

FORCE=0
RUN_USER="$(id -un)"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/legion-tweaks-install"
LOGFILE="$STATE_DIR/install.log"

# ============================ logging ============================
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
_logf(){ printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || true; }
step() { printf '\033[1;35m==>\033[0m %s\n' "$*"; _logf "[$(ts)] ==> $*"; }
log()  { printf '    %s\n' "$*";              _logf "[$(ts)]     $*"; }
warn() { printf '    \033[1;33mwarning:\033[0m %s\n' "$*"; _logf "[$(ts)]     warning: $*"; }
err()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2;      _logf "[$(ts)] !!! $*"; }
die()  { err "$*"; exit 1; }

# ============================ helpers ============================
have()       { command -v "$1" >/dev/null 2>&1; }
pkg_have()   { pacman -Q "$1" >/dev/null 2>&1; }
unit_exists(){ systemctl list-unit-files "$1" >/dev/null 2>&1 && systemctl cat "$1" >/dev/null 2>&1; }

# pacman -S --needed with PIPESTATUS check (tee keeps the log)
pac_install() {
  $SUDO pacman -S --needed --noconfirm "$@" 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ]
}

# enable + start unit(s), non-fatal
enable_now() {
  $SUDO systemctl enable --now "$@" 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ]
}

# write $2 (content) to file $1 via sudo, idempotently (skip if identical).
# sets global FILE_CHANGED=1 if it wrote a new/different file, 0 if already current.
FILE_CHANGED=0
write_file() {
  local path="$1" content="$2"
  FILE_CHANGED=0
  if [ "$FORCE" != 1 ] && [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
    log "skip: $path already up to date"; return 0
  fi
  printf '%s\n' "$content" | $SUDO tee "$path" >/dev/null || { err "could not write $path"; return 1; }
  FILE_CHANGED=1; log "wrote $path"
}

# install an executable systemd-sleep hook, idempotently
install_sleep_hook() {
  local path="$1" content="$2"
  if [ "$FORCE" != 1 ] && [ -x "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
    log "skip: $path already installed"; return 0
  fi
  printf '%s\n' "$content" | $SUDO tee "$path" >/dev/null || { err "could not write $path"; return 1; }
  $SUDO chmod 0755 "$path" || { err "chmod failed: $path"; return 1; }
  log "installed $path"
}

# regenerate grub.cfg (non-fatal)
regen_grub() {
  $SUDO grub-mkconfig -o "$GRUB_CFG" 2>&1 | tee -a "$LOGFILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || warn "grub-mkconfig returned non-zero (check the log)"
}

# ============================ preflight ============================
preflight() {
  step "Preflight checks"
  local prod bios biosok=0 p
  prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  log "product=${prod:-?}  bios=${bios:-?}  kernel=${KREL}  user=${RUN_USER}"
  for p in $EXPECT_BIOS_PREFIXES; do case "$bios" in ${p}*) biosok=1 ;; esac; done
  if [ "$prod" != "$EXPECT_PRODUCT" ] || [ "$biosok" != 1 ]; then
    if [ "$FORCE" = 1 ]; then
      warn "machine does not look like ${EXPECT_PRODUCT}/${EXPECT_BIOS_PREFIXES} -- proceeding due to --force"
    else
      die "this installer is specific to the Legion Pro 7 16IAX10H (product ${EXPECT_PRODUCT}, BIOS ${EXPECT_BIOS_PREFIXES}*). Detected product='${prod}' bios='${bios}'. Use --force only if you are certain."
    fi
  else
    log "machine matches Legion Pro 7 16IAX10H"
  fi
  have sudo || die "sudo not found"
}

# ============================ modules ============================

# --- HIGH: re-bind the AW88399 smart-amps after resume ---
mod_resume_audio() {
  step "[resume-audio] AW88399 amp DSP re-bind on resume (fixes speakers dying after suspend)"
  local content
  content="$(cat <<'HOOK'
#!/bin/sh
# /usr/lib/systemd/system-sleep/aw88399-resume-rebind
# Re-download the AW88399 DSP firmware after S3 resume by rebinding the amps.
#
# Why: on deep (S3) resume the AW88399 DSP RAM loses the .acf firmware. The
# kernel driver's system_resume only does a GPIO hw_reset and re-pushes the
# DSP firmware in a way that then fails aw_dev_fw_crc_check ("dsp crc check
# failed"), so the speakers go silent until reboot. Rebinding the i2c side
# codec re-runs .probe -> aw88399_request_firmware_file, which re-downloads
# /usr/lib/firmware/aw88399_acf.bin and re-registers the HDA component cleanly.

DRV=/sys/bus/i2c/drivers/aw88399-hda

case "$1" in
    post)
        [ -d "$DRV" ] || exit 0
        devs=""
        for l in "$DRV"/i2c-AWDZ8399:*; do
            [ -e "$l" ] || continue
            devs="$devs $(basename "$l")"
        done
        [ -n "$devs" ] || exit 0

        for d in $devs; do
            [ -e "$DRV/$d" ] && echo "$d" > "$DRV/unbind" 2>/dev/null
        done
        # brief settle so the i2c bus + GPIO reset complete before re-probe
        sleep 0.5
        for d in $devs; do
            echo "$d" > "$DRV/bind" 2>/dev/null
        done
        # retry once for any amp whose bind did not take (i2c/GPIO not yet settled)
        for d in $devs; do
            [ -e "$DRV/$d" ] || { sleep 0.3; echo "$d" > "$DRV/bind" 2>/dev/null; }
        done
        ;;
esac
exit 0
HOOK
)"
  install_sleep_hook "$SLEEPDIR/aw88399-resume-rebind" "$content" || return 1
  if [ ! -d "$AW_DRV" ]; then
    warn "aw88399-hda driver not loaded right now -- hook is installed and will act once the amp driver is present (boot the audio kernel)"
  else
    log "verified: amp driver present at $AW_DRV (hook will rebind its devices on resume)"
  fi
  log "test it: 'sudo systemctl suspend', wake, then play audio through the internal speakers"
}

# --- FIX: re-apply the RAPL cap after resume ---
mod_resume_power() {
  step "[resume-power] Re-apply Intel MMIO-RAPL cap after resume (S3 can reset it to ~30W)"
  if ! unit_exists "$POWERCAPD"; then
    warn "$POWERCAPD not installed -- run Build_16iax10h_power.sh first; skipping this module"
    return 0
  fi
  local content
  content="$(cat <<'HOOK'
#!/bin/sh
# /usr/lib/systemd/system-sleep/legion-powercap
# Re-apply the Intel MMIO-RAPL power cap after resume: S3 can reset the
# register to the BIOS ~30W default, and legion-powercapd only re-writes the
# limit when the Fn-Q mode/AC/target *key* changes -- which it does not across a
# resume. Restarting the daemon forces an unconditional re-apply.
case "$1" in
    post)
        systemctl is-enabled --quiet legion-powercapd.service && \
            systemctl restart legion-powercapd.service
        ;;
esac
exit 0
HOOK
)"
  install_sleep_hook "$SLEEPDIR/legion-powercap" "$content" || return 1
  log "after the next suspend/resume, '$RAPL_UW' should read ~90000000 (90W) or higher, not ~30000000"
}

# --- TUNE: cpupower performance -> powersave ---
mod_cpu_governor() {
  step "[cpu-governor] Switch cpupower governor from 'performance' to 'powersave' (dynamic HWP)"
  if [ ! -f "$CPUPOWER_CONF" ]; then
    warn "$CPUPOWER_CONF missing (cpupower package not installed?) -- skipping"
    return 0
  fi
  if [ "$FORCE" != 1 ] && grep -qE "^GOVERNOR=['\"]?powersave['\"]?" "$CPUPOWER_CONF"; then
    log "skip: GOVERNOR already 'powersave' in $CPUPOWER_CONF"
  else
    if grep -qE "^[[:space:]]*GOVERNOR=" "$CPUPOWER_CONF"; then
      # only ACTIVE (uncommented) GOVERNOR= lines; '#' excluded so commented
      # examples are left intact. replaces the whole line value, not just the key.
      $SUDO sed -i -E "s|^[[:space:]]*GOVERNOR=.*|GOVERNOR='powersave'|" "$CPUPOWER_CONF" \
        || { err "sed failed on $CPUPOWER_CONF"; return 1; }
    else
      printf "GOVERNOR='powersave'\n" | $SUDO tee -a "$CPUPOWER_CONF" >/dev/null \
        || { err "could not append to $CPUPOWER_CONF"; return 1; }
    fi
    log "set GOVERNOR='powersave' in $CPUPOWER_CONF"
  fi
  $SUDO systemctl enable cpupower.service >/dev/null 2>&1 || true
  $SUDO systemctl restart cpupower.service 2>&1 | tee -a "$LOGFILE" || warn "could not restart cpupower.service"
  local g; g="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
  log "cpu0 governor is now: ${g:-unknown}  (under load it still boosts to full turbo)"
  if [ -f "${CPUPOWER_CONF}.pacnew" ]; then
    warn "${CPUPOWER_CONF}.pacnew exists -- a package update shipped a new default; merge it with: vimdiff $CPUPOWER_CONF ${CPUPOWER_CONF}.pacnew"
  fi
}

# --- SAFETY: bootable Btrfs snapshots ---
mod_snapshots() {
  step "[snapshots] Btrfs rollback: snapper + snap-pac + grub-btrfs"
  local rootfs; rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  if [ "$rootfs" != "btrfs" ]; then
    warn "/ is '$rootfs', not btrfs -- skipping snapshots"
    return 0
  fi
  pac_install snapper snap-pac grub-btrfs inotify-tools || { err "pacman failed installing snapshot tools"; return 1; }

  # root (/) config
  if $SUDO snapper -c root get-config >/dev/null 2>&1; then
    log "skip: snapper 'root' config already exists"
  else
    if [ -e /.snapshots ] && ! $SUDO btrfs subvolume show /.snapshots >/dev/null 2>&1; then
      $SUDO rmdir /.snapshots 2>/dev/null || warn "could not remove stray /.snapshots (not a subvolume)"
    fi
    $SUDO snapper -c root create-config / || { err "snapper create-config root failed"; return 1; }
    $SUDO snapper -c root set-config 'TIMELINE_CREATE=no' 'NUMBER_LIMIT=10' 'NUMBER_LIMIT_IMPORTANT=10' \
      "ALLOW_USERS=$RUN_USER" 'SYNC_ACL=yes' || warn "snapper root set-config partial"
    log "created snapper 'root' config (snap-pac will snapshot it on every pacman transaction)"
  fi

  # home (/home) config -- only if /home is its own btrfs subvolume
  if findmnt -no FSTYPE /home 2>/dev/null | grep -q btrfs; then
    if $SUDO snapper -c home get-config >/dev/null 2>&1; then
      log "skip: snapper 'home' config already exists"
    else
      if [ -e /home/.snapshots ] && ! $SUDO btrfs subvolume show /home/.snapshots >/dev/null 2>&1; then
        $SUDO rmdir /home/.snapshots 2>/dev/null || warn "could not remove stray /home/.snapshots"
      fi
      $SUDO snapper -c home create-config /home || { err "snapper create-config home failed"; return 1; }
      $SUDO snapper -c home set-config 'TIMELINE_CREATE=yes' 'TIMELINE_LIMIT_HOURLY=5' 'TIMELINE_LIMIT_DAILY=7' \
        'TIMELINE_LIMIT_WEEKLY=0' 'TIMELINE_LIMIT_MONTHLY=0' "ALLOW_USERS=$RUN_USER" 'SYNC_ACL=yes' \
        || warn "snapper home set-config partial"
      log "created snapper 'home' config (timeline snapshots only; snap-pac does NOT touch /home)"
    fi
  else
    log "note: /home is not a separate btrfs subvolume -- skipping a 'home' snapper config"
  fi

  enable_now snapper-cleanup.timer snapper-timeline.timer || warn "could not enable snapper timers"
  enable_now grub-btrfsd || warn "could not enable grub-btrfsd (the snapshot->GRUB watcher)"
  regen_grub
  log "rollback later from a booted snapshot with:  sudo snapper rollback <N>   (then reboot)"
  log "note: @log and @pkg are separate subvols, so /var/log and the pacman cache are NOT in a root snapshot (by design)"
}

# --- SAFETY: monthly btrfs scrub on / ---
mod_btrfs_scrub() {
  step "[btrfs-scrub] Enable monthly Btrfs scrub on / (detects silent bit-rot)"
  local rootfs; rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  if [ "$rootfs" != "btrfs" ]; then
    warn "/ is '$rootfs', not btrfs -- skipping scrub timer"
    return 0
  fi
  enable_now 'btrfs-scrub@-.timer' || { err "could not enable btrfs-scrub@-.timer"; return 1; }
  log "scrub timer active: $(systemctl is-enabled 'btrfs-scrub@-.timer' 2>/dev/null || echo '?')  (run now anytime: sudo btrfs scrub start /)"
}

# --- TUNE: grow zram swap ---
mod_zram() {
  step "[zram] Grow zram swap toward RAM (headroom for kernel/DKMS builds)"
  if ! pkg_have zram-generator; then
    warn "zram-generator not installed -- installing"
    pac_install zram-generator || { err "pacman failed installing zram-generator"; return 1; }
  fi
  local content used_kb
  content="$(cat <<'CONF'
[zram0]
# size = min(total RAM, 24 GiB); zstd; high priority so it is used before any disk swap
zram-size = min(ram, 24576)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
CONF
)"
  write_file "$ZRAM_CONF" "$content" || return 1
  if [ "$FILE_CHANGED" = 1 ]; then
    # Restarting this service first stops the bound dev-zram0.swap unit, i.e.
    # swapoff /dev/zram0, which must fault every paged-out page back into RAM.
    # zram0 is the only swap, so if it is in use this can OOM/stall. Only restart
    # when swap is (near) empty; otherwise the new size applies on next boot.
    # Use the /proc/swaps Used column (decompressed), not zramctl USED (compressed).
    used_kb="$(awk '$1=="/dev/zram0"{print $4}' /proc/swaps 2>/dev/null)"
    if [ -z "${used_kb:-}" ] || { [ "${used_kb:-0}" -lt 65536 ] 2>/dev/null; }; then
      $SUDO systemctl restart "systemd-zram-setup@zram0.service" 2>&1 | tee -a "$LOGFILE" \
        || warn "could not restart systemd-zram-setup@zram0 (a reboot will apply it)"
    else
      warn "zram swap in use (${used_kb} KiB paged out); not restarting to avoid swapoff under memory pressure -- new size applies after reboot"
    fi
  fi
  log "current zram: $(zramctl --noheadings --output NAME,DISKSIZE,ALGORITHM 2>/dev/null | tr -s ' ' || echo '?')"
}

# --- TUNE: pin deep/S3 ---
mod_suspend_deep() {
  step "[suspend-deep] Pin mem_sleep_default=deep (already active; prevents a quirk flip to s2idle)"
  if [ ! -f "$GRUB_DEFAULT" ]; then
    warn "$GRUB_DEFAULT not found -- skipping (non-GRUB system?)"
    return 0
  fi
  if [ "$FORCE" != 1 ] && grep -q 'mem_sleep_default=deep' "$GRUB_DEFAULT"; then
    log "skip: mem_sleep_default=deep already in $GRUB_DEFAULT"
    return 0
  fi
  if grep -q 'mem_sleep_default=' "$GRUB_DEFAULT"; then
    warn "an existing mem_sleep_default= is present in $GRUB_DEFAULT -- leaving it; edit by hand (vim) if you want 'deep'"
    return 0
  fi
  $SUDO sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="\)/\1mem_sleep_default=deep /' "$GRUB_DEFAULT" \
    || { err "sed failed on $GRUB_DEFAULT"; return 1; }
  grep -q 'mem_sleep_default=deep' "$GRUB_DEFAULT" || { err "edit did not take -- inspect $GRUB_DEFAULT"; return 1; }
  log "added mem_sleep_default=deep to GRUB_CMDLINE_LINUX_DEFAULT"
  regen_grub
  log "applies on next boot ('cat /sys/power/mem_sleep' should then show '[deep]')"
}

# --- FEAT: Intel iGPU hardware video decode ---
mod_video_accel() {
  step "[video-accel] Intel iGPU hardware video decode (intel-media-driver / iHD)"
  pac_install intel-media-driver libva-utils vulkan-intel || { err "pacman failed"; return 1; }
  if have vainfo; then
    # render-node numbering is probe-order dependent on this Intel+NVIDIA box,
    # so probe every node and take the best match (the Intel iGPU one)
    local r=0 n c
    for n in /dev/dri/renderD*; do
      [ -e "$n" ] || continue
      c="$(vainfo --display drm --device "$n" 2>/dev/null | grep -ciE 'VAProfile(H264|HEVC|AV1|VP9)' || true)"
      [ "${c:-0}" -gt "$r" ] 2>/dev/null && r="$c"
    done
    log "iGPU VA-API decode profiles detected: ${r:-0} (H264/HEVC/AV1/VP9)"
  fi
  log "to route browsers/players at the iGPU, set 'LIBVA_DRIVER_NAME=iHD' in your Hyprland env (edit with vim; not auto-changed)"
}

# --- FEAT: nvidia prime offload ---
mod_gpu_offload() {
  step "[gpu-offload] nvidia-prime -> 'prime-run <app>' for per-app dGPU offload"
  pac_install nvidia-prime mesa-utils || { err "pacman failed"; return 1; }
  have prime-run && log "installed: run a game/app on the dGPU with 'prime-run <command>' (e.g. 'prime-run glxinfo | grep renderer')" \
                 || warn "prime-run not found after install (unexpected)"
}

# --- FEAT: thunderbolt authorization ---
mod_thunderbolt() {
  step "[thunderbolt] bolt (boltd) for Thunderbolt 4 device authorization"
  pac_install bolt || { err "pacman failed installing bolt"; return 1; }
  # boltd is D-Bus/udev-activated; do NOT 'systemctl enable' it.
  if boltctl domains >/dev/null 2>&1; then
    log "boltd reachable; TB security level: $(boltctl domains 2>/dev/null | awk -F': *' '/security/{print $2; exit}')"
  else
    log "bolt installed; boltd will activate on demand. Approve a device later with: boltctl enroll <uuid>"
  fi
}

# --- FEAT: firmware updates ---
mod_firmware() {
  step "[firmware] fwupd metadata refresh + fwupd-refresh.timer"
  if ! pkg_have fwupd; then
    warn "fwupd not installed -- installing"
    pac_install fwupd || { err "pacman failed installing fwupd"; return 1; }
  fi
  enable_now fwupd-refresh.timer || warn "could not enable fwupd-refresh.timer"
  $SUDO fwupdmgr refresh --force >/dev/null 2>&1 || warn "fwupd metadata refresh failed (network?) -- not fatal"
  log "check for updates anytime with: fwupdmgr get-updates   (apply: sudo fwupdmgr update; many flashes need AC)"
  log "note: Lenovo consumer/Legion BIOS is usually NOT on LVFS -- check the 83F5/16IAX10H support page by hand"
}

# --- FEAT (speculative): NVIDIA Dynamic Boost ---
mod_nvidia_powerd() {
  step "[nvidia-powerd] NVIDIA Dynamic Boost (auto-reverts if BIOS lacks NVPCF on this SKU)"
  if ! unit_exists nvidia-powerd.service; then
    warn "nvidia-powerd.service not present (nvidia-utils?) -- skipping"
    return 0
  fi
  if systemctl is-masked nvidia-powerd.service >/dev/null 2>&1; then
    log "skip: previously masked here (determined unsupported on this machine)"
    return 0
  fi
  $SUDO systemctl enable --now nvidia-powerd.service 2>&1 | tee -a "$LOGFILE" || true
  sleep 2
  local jr; jr="$(journalctl -u nvidia-powerd.service -b --no-pager 2>/dev/null || true)"
  if grep -qiE 'SBIOS support not found|NVPCF' <<<"$jr"; then
    warn "Dynamic Boost unsupported by BIOS ${EXPECT_PRODUCT}/Q7CN (no NVPCF) -- masking to stop log noise"
    $SUDO systemctl disable --now nvidia-powerd.service >/dev/null 2>&1 || true
    $SUDO systemctl mask nvidia-powerd.service >/dev/null 2>&1 || true
  elif systemctl is-active nvidia-powerd.service >/dev/null 2>&1; then
    log "nvidia-powerd active. Verify under a GPU load on AC: 'nvidia-smi -q -d POWER' (limit should climb past 80W)"
  else
    warn "nvidia-powerd did not stay active; leaving as-is (inspect: journalctl -u nvidia-powerd.service -b)"
  fi
}

# --- INFO (read-only): battery wear + charge-limit availability ---
mod_battery_info() {
  step "[battery-info] Battery health + charge-limit availability (READ-ONLY -- no EC writes)"
  local bat="" d
  for d in /sys/class/power_supply/BAT*; do [ -d "$d" ] && { bat="$d"; break; }; done
  if [ -z "$bat" ]; then warn "no BAT* battery found"; return 0; fi
  local cap cyc fd dfd wear="?"
  cap="$(cat "$bat/capacity" 2>/dev/null || echo '?')"
  cyc="$(cat "$bat/cycle_count" 2>/dev/null || echo '?')"
  fd="$(cat "$bat/charge_full_design" 2>/dev/null || cat "$bat/energy_full_design" 2>/dev/null || echo '')"
  dfd="$(cat "$bat/charge_full" 2>/dev/null || cat "$bat/energy_full" 2>/dev/null || echo '')"
  if [ -n "$fd" ] && [ -n "$dfd" ] && [ "$fd" -gt 0 ] 2>/dev/null; then
    wear="$(awk -v a="$dfd" -v b="$fd" 'BEGIN{printf "%.1f", (1-a/b)*100}')"
  fi
  log "charge now: ${cap}%   cycle_count: ${cyc}   wear: ${wear}%"
  if ls /sys/class/power_supply/BAT*/charge_control_end_threshold >/dev/null 2>&1; then
    local thr; thr="$(cat /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -1)"
    log "charge-limit interface IS available (end threshold = ${thr}%). Cap it with e.g.:"
    log "  echo 80 | sudo tee /sys/class/power_supply/${bat##*/}/charge_control_end_threshold"
  else
    warn "NO battery charge-limit interface on this machine (no charge_control_* / conservation_mode)."
    log "  - the legion fork exposes only 'rapidcharge'; ideapad_laptop (which owns conservation_mode) is blacklisted by the power install."
    log "  - there is NO verified-safe way to cap charging today: writing unknown EC/SBMC codes may be a silent no-op or risk the EC."
    log "  - practical mitigation: avoid long stretches pinned at 100% on AC."
    log "  - to investigate the firmware later (read-only):"
    log "      sudo pacman -S --needed acpica && sudo cp /sys/firmware/acpi/tables/DSDT /tmp/dsdt.aml && iasl -d /tmp/dsdt.aml && grep -nE 'Method \\(SBMC|Method \\(GBMD' /tmp/dsdt.dsl"
  fi
}

# --- OPT: silence the cosmetic spd5118 resume error ---
mod_spd5118() {
  step "[spd5118] Blacklist the redundant DIMM temp sensor (silences a benign resume error)"
  write_file /etc/modprobe.d/blacklist-spd5118.conf "blacklist spd5118" || return 1
  $SUDO modprobe -r spd5118 2>/dev/null || true
  log "applied (fully effective next boot). You lose DIMM SPD temperature readings; drop this once the i801 fix lands."
}

# ============================ verification ============================
VPASS=0; VFAIL=0; VWARN=0
vok()   { VPASS=$((VPASS+1)); printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; _logf "    [ ok ] $*"; }
vfail() { VFAIL=$((VFAIL+1)); printf '    \033[0;31m[FAIL]\033[0m %s\n' "$*"; _logf "    [FAIL] $*"; }
vwarn() { VWARN=$((VWARN+1)); printf '    \033[1;33m[warn]\033[0m %s\n' "$*"; _logf "    [warn] $*"; }
vnote() {                     printf '    \033[0;36m[note]\033[0m %s\n' "$*"; _logf "    [note] $*"; }

do_verify() {
  step "Verification (read-only)"
  local prod bios g cmdline

  prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  case "$bios" in Q7CN*|SMCN*) vok "machine: ${prod} / ${bios}" ;; *) vwarn "machine: ${prod} / ${bios} (not Q7CN/SMCN)" ;; esac

  # resume hooks (the real correctness fixes)
  [ -x "$SLEEPDIR/aw88399-resume-rebind" ] && vok "resume hook present: aw88399-resume-rebind" \
    || vfail "missing/!exec: $SLEEPDIR/aw88399-resume-rebind (speakers will break after suspend) -- run: ./$(basename "$0") resume-audio"
  if unit_exists "$POWERCAPD"; then
    [ -x "$SLEEPDIR/legion-powercap" ] && vok "resume hook present: legion-powercap (RAPL re-apply)" \
      || vfail "missing/!exec: $SLEEPDIR/legion-powercap (RAPL cap can drop to ~30W after resume) -- run: ./$(basename "$0") resume-power"
  else
    vnote "legion-powercapd not installed -- resume-power hook not applicable (install Build_16iax10h_power.sh)"
  fi

  # cpu governor
  g="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
  case "$g" in
    powersave) vok "cpu governor: powersave (dynamic; still full turbo under load)" ;;
    performance) vwarn "cpu governor: performance (unconditional; gentler is 'powersave') -- run: ./$(basename "$0") cpu-governor" ;;
    *) vnote "cpu governor: ${g:-unknown}" ;;
  esac

  # snapshots
  if have snapper; then
    snapper -c root get-config >/dev/null 2>&1 && vok "snapper 'root' config present" || vwarn "snapper installed but no 'root' config"
    systemctl is-enabled grub-btrfsd >/dev/null 2>&1 && vok "grub-btrfsd enabled (snapshots appear in GRUB)" || vwarn "grub-btrfsd not enabled"
    pkg_have snap-pac && vok "snap-pac present (auto-snapshot per pacman txn)" || vwarn "snap-pac not installed"
  else
    vnote "snapper not installed (snapshots module not run)"
  fi

  # btrfs scrub
  systemctl is-enabled 'btrfs-scrub@-.timer' >/dev/null 2>&1 && vok "btrfs-scrub@-.timer enabled" || vwarn "btrfs scrub timer not enabled"

  # zram
  if [ -f "$ZRAM_CONF" ]; then
    grep -q 'min(ram' "$ZRAM_CONF" && vok "zram config grown ($ZRAM_CONF)" || vnote "zram config present but not the grown profile"
  else
    vnote "no $ZRAM_CONF (using package default zram size)"
  fi

  # suspend deep
  cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
  if grep -q 'mem_sleep_default=deep' "$GRUB_DEFAULT" 2>/dev/null; then
    grep -q 'mem_sleep_default=deep' <<<"$cmdline" && vok "deep/S3 pinned (in GRUB + active on cmdline)" \
      || vwarn "deep pinned in $GRUB_DEFAULT but not yet on cmdline (reboot to apply)"
  else
    vnote "mem_sleep_default not pinned ($(cat /sys/power/mem_sleep 2>/dev/null || echo '?'))"
  fi

  # feature packages
  pkg_have intel-media-driver && vok "intel-media-driver present (iGPU HW decode)" || vwarn "intel-media-driver not installed"
  pkg_have nvidia-prime && vok "nvidia-prime present (prime-run offload)" || vwarn "nvidia-prime not installed"
  pkg_have bolt && vok "bolt present (Thunderbolt authorization)" || vwarn "bolt not installed"
  systemctl is-enabled fwupd-refresh.timer >/dev/null 2>&1 && vok "fwupd-refresh.timer enabled" || vwarn "fwupd-refresh.timer not enabled"

  # nvidia-powerd state (informational)
  if unit_exists nvidia-powerd.service; then
    if systemctl is-masked nvidia-powerd.service >/dev/null 2>&1; then vnote "nvidia-powerd masked (Dynamic Boost unsupported on this BIOS)"
    elif systemctl is-active nvidia-powerd.service >/dev/null 2>&1; then vok "nvidia-powerd active (verify under load: nvidia-smi -q -d POWER)"
    else vnote "nvidia-powerd present but inactive"
    fi
  fi

  # spd5118 (opt-in)
  [ -f /etc/modprobe.d/blacklist-spd5118.conf ] && vnote "spd5118 blacklisted (opt-in; DIMM temp sensor silenced)"

  # battery charge limit (informational)
  ls /sys/class/power_supply/BAT*/charge_control_end_threshold >/dev/null 2>&1 \
    && vnote "battery charge-limit interface available" \
    || vnote "battery charge-limit NOT available on this machine (expected; see battery-info)"

  step "Result: ${VPASS} passed, ${VFAIL} failed, ${VWARN} warning(s)"
  if [ "$VFAIL" -eq 0 ]; then
    log "No critical gaps. [warn] = an optional feature/module you have not run; [note] = informational."
    return 0
  fi
  err "${VFAIL} critical check(s) failed (the resume fixes). Re-run the named module(s) above."
  return 1
}

# ============================ main ============================
ACTION="install"
REQ_MODULES=""
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)         FORCE=1 ;;
      --verify|--test) ACTION=verify ;;
      --list)          ACTION=list ;;
      -h|--help)       usage; exit 0 ;;
      --*)             die "unknown option: $1 (try --help)" ;;
      all)             REQ_MODULES="$ALL_MODULES" ;;
      *)
        case " $ALL_MODULES " in
          *" $1 "*) REQ_MODULES="${REQ_MODULES:+$REQ_MODULES }$1" ;;
          *) die "unknown module: '$1' (try --list)" ;;
        esac
        ;;
    esac
    shift
  done
}
parse_args "$@"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [ "$ACTION" = list ]; then
  step "Available modules"
  log "default set (no args): $DEFAULT_MODULES"
  log "opt-in (name it or 'all'): spd5118"
  log ""
  log "run a subset:  ./$(basename "$0") resume-audio cpu-governor"
  log "run all:       ./$(basename "$0") all"
  log "health check:  ./$(basename "$0") --verify"
  exit 0
fi

if [ "$ACTION" = verify ]; then
  do_verify
  exit $?
fi

# choose modules: explicit request, else default set
MODULES="${REQ_MODULES:-$DEFAULT_MODULES}"

step "Build_16iax10h_tweaks.sh  (user=$RUN_USER, force=$FORCE, kernel=$KREL)"
log "modules: $MODULES"
preflight

MOD_OK=0; MOD_FAIL=0
for m in $MODULES; do
  fn="mod_${m//-/_}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    warn "no implementation for module '$m' -- skipping"; MOD_FAIL=$((MOD_FAIL+1)); continue
  fi
  if "$fn"; then MOD_OK=$((MOD_OK+1)); else warn "module '$m' reported a problem (continuing with the rest)"; MOD_FAIL=$((MOD_FAIL+1)); fi
done

step "Done: ${MOD_OK} module(s) OK, ${MOD_FAIL} with problems"
log "Health check:  ./$(basename "$0") --verify"
log "Some changes (suspend-deep, spd5118, zram) fully apply after a REBOOT."
log "Install log: $LOGFILE"
[ "$MOD_FAIL" -eq 0 ] || exit 1
exit 0
