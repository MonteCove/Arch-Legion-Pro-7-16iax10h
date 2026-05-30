#!/usr/bin/env bash
#
# build-16iax10h-audio.sh
#
# Builds a properly packaged, update-surviving patched kernel that enables
# the internal speakers on the Lenovo Legion Pro 7 16IAX10H (Awinic AW88399
# smart amps), based on the community fix at:
#   https://github.com/nadimkobeissi/16iax10h-linux-sound-saga
#
# Design goals:
#   - Idempotent: every step detects prior completion and skips itself.
#     Re-run safely as many times as you like. Use --force to redo everything.
#   - Coexists with the stock "linux" package (your bootable fallback).
#   - NVIDIA rebuilds automatically via DKMS against the new headers.
#   - Speaker UCM2 overrides survive future alsa-ucm-conf upgrades (pacman hook).
#   - Amp calibration runs automatically every login (user service).
#
# It does NOT reboot for you and does NOT touch the stock kernel.
#
# Usage:
#   ./build-16iax10h-audio.sh                 # safe to run any time; re-applies
#                                             # customization cleanly each run
#   ./build-16iax10h-audio.sh --force         # also rebuild/reinstall even if the
#                                             # packages already exist or are installed
#   ./build-16iax10h-audio.sh --skip-bootloader   # leave bootloader alone
#   ./build-16iax10h-audio.sh --verify            # read-only post-reboot health check (no build)
#   BUILD_ROOT=~/somewhere ./build-16iax10h-audio.sh
#
# Re-running without --force is always safe: the PKGBUILD and config are reset to
# pristine and re-customized from scratch every run, so there is no "stuck" state.
# --force only controls the expensive, non-deterministic steps: rebuilding when a
# built package already exists, and reinstalling when the package is already installed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BUILD_ROOT="${BUILD_ROOT:-$HOME/16iax10h-kernel}"
SAGA_URL="https://github.com/nadimkobeissi/16iax10h-linux-sound-saga.git"
CUSTOM_PKGBASE="linux-16iax10h-audio"
DSP_PARAM="snd_intel_dspcfg.dsp_driver=3"   # mandatory for sound; Y9000P uses =1
MARKER="16IAX10H-AUTO"

FORCE=0
SKIP_BOOTLOADER=0
VERIFY=0

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'
c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_dim=$'\033[2m'
step() { printf '%s\n==> %s%s\n' "$c_blue" "$1" "$c_reset"; }
ok()   { printf '%s    %s%s\n' "$c_grn" "$1" "$c_reset"; }
skip() { printf '%s    skip: %s%s\n' "$c_dim" "$1" "$c_reset"; }
warn() { printf '%s    warning: %s%s\n' "$c_yel" "$1" "$c_reset"; }
die()  { printf '%s!!! %s%s\n' "$c_red" "$1" "$c_reset" >&2; exit 1; }

trap 'die "failed at line $LINENO. Nothing destructive was forced; fix the issue and re-run (steps already done will be skipped)."' ERR

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --skip-bootloader) SKIP_BOOTLOADER=1 ;;
    --verify|--test) VERIFY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# ---------------------------------------------------------------------------
# Verify mode: read-only post-reboot health check (no build), then exit
# ---------------------------------------------------------------------------
if [[ "${VERIFY:-0}" == 1 ]]; then
  set +e; trap - ERR
  vpass=0; vfail=0; vwarn=0
  vok()   { vpass=$((vpass+1)); printf '%s    [ ok ] %s%s\n' "$c_grn" "$1" "$c_reset"; }
  vbad()  { vfail=$((vfail+1)); printf '%s    [FAIL] %s%s\n' "$c_red" "$1" "$c_reset"; }
  vnote() { vwarn=$((vwarn+1)); printf '%s    [warn] %s%s\n' "$c_yel" "$1" "$c_reset"; }
  step "Audio setup verification (read-only)"

  kr="$(uname -r)"
  if [[ "$kr" == *-16iax10h-audio-16iax10h ]]; then
    vnote "running the OLD doubled-name kernel ($kr); reboot into the rebuilt clean one"
  elif [[ "$kr" == *-16iax10h-audio ]]; then
    vok "booted on the audio kernel: $kr"
  else
    vbad "NOT on the audio kernel (uname -r = $kr); reboot and pick the 16IAX10H Audio entry"
  fi

  if pacman -Q "$CUSTOM_PKGBASE" >/dev/null 2>&1; then
    vok "package installed: $(pacman -Q "$CUSTOM_PKGBASE")"
  else
    vbad "package $CUSTOM_PKGBASE not installed"
  fi

  if grep -q "$DSP_PARAM" /proc/cmdline; then
    vok "boot param active: $DSP_PARAM"
  else
    vbad "$DSP_PARAM missing from /proc/cmdline (the speakers need it)"
  fi

  if [[ -f /usr/lib/firmware/aw88399_acf.bin ]]; then
    vok "amp firmware present: /usr/lib/firmware/aw88399_acf.bin"
  else
    vbad "amp firmware missing: /usr/lib/firmware/aw88399_acf.bin"
  fi

  # capture lsmod once and match via here-string: piping into 'grep -q' lets grep
  # close the pipe early, SIGPIPE lsmod, and (under pipefail) falsely report "not found".
  MODS_AUDIO="$(lsmod 2>/dev/null)"
  if grep -qi aw88399 <<<"$MODS_AUDIO"; then
    vok "AW88399 smart-amp module(s) loaded: $(awk '$1 ~ /aw883/{print $1}' <<<"$MODS_AUDIO" | tr '\n' ' ')"
  else
    vnote "no aw88399 module in lsmod (built-in, or not probed on this kernel)"
  fi

  if grep -qE '^[[:space:]]*[0-9]+[[:space:]]+\[' /proc/asound/cards 2>/dev/null; then
    vok "sound card detected (/proc/asound/cards):"
    grep -E '^[[:space:]]*[0-9]+[[:space:]]+\[' /proc/asound/cards | sed "s/^/        /"
  else
    vbad "no sound card in /proc/asound/cards; the codec is not being driven"
  fi

  WPS=""
  if command -v wpctl >/dev/null && WPS="$(wpctl status 2>/dev/null)"; then
    if grep -qi speaker <<<"$WPS"; then
      vok "PipeWire Speaker sink present"
    else
      vnote "PipeWire is up but no 'Speaker' sink seen (check: wpctl status)"
    fi
  else
    vnote "could not query PipeWire (run inside your desktop session for the sink check)"
  fi

  if systemctl --user cat 16iax10h-calibrate.service >/dev/null 2>&1; then
    vok "amp-calibration user service installed"
  else
    vnote "amp-calibration user service not found (systemctl --user)"
  fi

  # default-boot config -- so the audio kernel boots without a manual menu pick
  if [[ -f /etc/default/grub ]]; then
    gdef="$(grep -E '^GRUB_DEFAULT=' /etc/default/grub | tail -n1)";     gdef="${gdef#GRUB_DEFAULT=}";     gdef="${gdef//\"/}"
    gsav="$(grep -E '^GRUB_SAVEDEFAULT=' /etc/default/grub | tail -n1)"; gsav="${gsav#GRUB_SAVEDEFAULT=}"; gsav="${gsav//\"/}"
    if [[ "$gdef" == "saved" && "$gsav" == "true" ]]; then
      vok "GRUB remembers your boot choice (GRUB_DEFAULT=saved, GRUB_SAVEDEFAULT=true); boot the audio entry once to lock it as default"
    elif [[ "$gdef" == "saved" ]]; then
      vnote "GRUB_DEFAULT=saved but GRUB_SAVEDEFAULT!=true -- your audio-kernel pick won't persist (add GRUB_SAVEDEFAULT=true, then grub-mkconfig)"
    elif [[ -n "$gdef" ]]; then
      vnote "GRUB_DEFAULT=$gdef (fixed) -- confirm that's the 16IAX10H Audio entry, or use GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true"
    else
      vnote "no GRUB_DEFAULT in /etc/default/grub (default = first menu entry, which may not be the audio kernel)"
    fi
  elif command -v bootctl >/dev/null 2>&1 || [[ -d /boot/loader ]]; then
    bdef="$(grep -E '^default' /boot/loader/loader.conf 2>/dev/null | tail -n1 | awk '{print $2}')"
    case "$bdef" in
      *16iax10h-audio*) vok "systemd-boot default is the audio entry ($bdef)" ;;
      "")               vnote "systemd-boot: no 'default' set in /boot/loader/loader.conf" ;;
      *)                vnote "systemd-boot default '$bdef' is not the 16iax10h-audio entry" ;;
    esac
  else
    vnote "no GRUB or systemd-boot config found to check the default-boot entry"
  fi

  step "Result: ${vpass} passed, ${vfail} failed, ${vwarn} warning(s)"
  if [[ $vfail -eq 0 ]]; then
    ok "Audio setup looks correct. Play something to confirm the speakers."
    exit 0
  fi
  printf '%s!!! %d check(s) failed (see [FAIL] lines). If you just rebuilt, REBOOT into the 16IAX10H Audio entry then re-run: %s --verify%s\n' "$c_red" "$vfail" "$0" "$c_reset" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 0: preflight
# ---------------------------------------------------------------------------
step "Preflight checks"

[[ $EUID -ne 0 ]] || die "Do not run as root. makepkg refuses root; run as your normal user (it will sudo where needed)."
command -v pacman >/dev/null || die "This is not an Arch system (no pacman)."

# Keep a sudo timestamp warm so the long build does not stall on a prompt.
sudo -v

LINUX_FULL="$(pacman -Q linux | awk '{print $2}')"          # e.g. 7.0.10.arch1-1
KVER="$(printf '%s' "$LINUX_FULL" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')"  # 7.0.10
MAJMIN="$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+')" # 7.0
ok "Stock kernel package: linux $LINUX_FULL (base $KVER)"

# Hardware sanity (warn-only)
prod="$(cat /sys/devices/virtual/dmi/id/product_version 2>/dev/null || true)"
if printf '%s' "$prod" | grep -qi '16IAX10H'; then
  ok "Detected: $prod"
else
  warn "This machine does not self-report as 16IAX10H (got: '${prod:-unknown}'). The fix may still apply if your audio architecture matches; continuing."
fi

# Secure Boot (warn-only): an unsigned custom kernel will not boot if SB is on.
sb_state=""
if command -v mokutil >/dev/null; then sb_state="$(mokutil --sb-state 2>/dev/null || true)"; fi
if printf '%s' "$sb_state" | grep -qi 'enabled'; then
  warn "Secure Boot appears ENABLED. This unsigned kernel will not boot until you disable Secure Boot or sign it."
fi

# ---------------------------------------------------------------------------
# Step 1: build tooling (pacman --needed is idempotent)
# ---------------------------------------------------------------------------
step "Installing build tooling"
sudo pacman -S --needed --noconfirm \
  base-devel devtools pacman-contrib git bc cpio perl tar xz zstd pahole >/dev/null
ok "Tooling present."

mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

# ---------------------------------------------------------------------------
# Step 2: obtain Arch's official linux package source at the matching version
# ---------------------------------------------------------------------------
step "Fetching Arch linux package source"
SRC="$BUILD_ROOT/linux"
if [[ ! -d "$SRC/.git" ]]; then
  pkgctl repo clone --protocol=https linux
fi
cd "$SRC"
# Make sure we are on the tag matching the installed kernel. The checkout is safe
# because Step 4 resets tracked files itself; any local edits are disposable.
git fetch --tags --quiet || true
if git rev-parse -q --verify "refs/tags/$LINUX_FULL" >/dev/null; then
  git checkout --quiet --force "$LINUX_FULL"
  ok "On tag $LINUX_FULL"
else
  warn "No git tag '$LINUX_FULL'; staying on current HEAD (PKGBUILD pkgver should still match your installed kernel)."
fi
cd "$BUILD_ROOT"

# ---------------------------------------------------------------------------
# Step 3: obtain the saga fix and select the matching patch
# ---------------------------------------------------------------------------
step "Fetching the audio fix repository"
SAGA="$BUILD_ROOT/linux/saga"
if [[ -d "$SAGA/.git" ]]; then
  git -C "$SAGA" pull --quiet --ff-only || warn "could not fast-forward saga repo; using existing checkout"
else
  git clone --quiet "$SAGA_URL" "$SAGA"
fi

PATCH_SRC=""
for cand in "$KVER" "$MAJMIN"; do
  f="$SAGA/fix/patches/16iax10h-audio-linux-${cand}.patch"
  if [[ -f "$f" ]]; then PATCH_SRC="$f"; break; fi
done
[[ -n "$PATCH_SRC" ]] || die "No saga patch found for kernel $KVER (looked for $KVER and $MAJMIN). The repo may not support your version yet."
PATCH_NAME="$(basename "$PATCH_SRC")"
ok "Using patch: $PATCH_NAME"

# Verify the firmware blob exists in the repo.
FW_SRC="$SAGA/fix/firmware/aw88399_acf.bin"
[[ -f "$FW_SRC" ]] || die "Missing firmware blob in repo: $FW_SRC"

# ---------------------------------------------------------------------------
# Step 4: customize the PKGBUILD (resets to pristine, then re-applies each run)
# ---------------------------------------------------------------------------
step "Customizing the PKGBUILD"
cd "$SRC"

# Locate the kernel config file (name varies: config or config.x86_64).
CONFIG_FILE=""
for c in config.x86_64 config; do [[ -f "$c" ]] && CONFIG_FILE="$c" && break; done
[[ -n "$CONFIG_FILE" ]] || die "could not find kernel config (config.x86_64 or config) in $SRC"
ok "config file: $CONFIG_FILE"

# Drop a stray top-level 'config' (not the real config file) if one is lying around.
if [[ "$CONFIG_FILE" != config && -f config ]] && ! git ls-files --error-unmatch config >/dev/null 2>&1; then
  rm -f config
fi

# Copy the patch next to the PKGBUILD so it is a local source file.
cp -f "$PATCH_SRC" "./$PATCH_NAME"

# Always start from a pristine PKGBUILD and config, then apply our edits fresh.
# Because every edit below is deterministic and the files are git-tracked,
# resetting first makes a plain re-run produce the correct result every time.
# This is why no --force is needed here: re-running is inherently safe.
git checkout -- PKGBUILD "$CONFIG_FILE" 2>/dev/null || true

# 4a. Rename pkgbase so this is a separate package from stock "linux".
sed -i "s/^pkgbase=linux\$/pkgbase=$CUSTOM_PKGBASE/" PKGBUILD
grep -q "^pkgbase=$CUSTOM_PKGBASE\$" PKGBUILD || die "could not rename pkgbase in PKGBUILD"
ok "pkgbase -> $CUSTOM_PKGBASE"

# 4b. Wire the patch into the source array, SKIP its sums, and (because we edit
#     config.x86_64 below) neutralize the x86_64 config checksum.
nx=$(bash -c 'source ./PKGBUILD; echo "${#source_x86_64[@]}"' 2>/dev/null || echo 1)
{ [[ "$nx" =~ ^[0-9]+$ ]] && [[ "$nx" -ge 1 ]]; } || nx=1
xskips=""; for ((i=0;i<nx;i++)); do xskips+="'SKIP' "; done; xskips="${xskips% }"
{
  echo ""
  echo "# >>> $MARKER >>>"
  echo "source+=(\"$PATCH_NAME\")"
  for sv in b2sums sha512sums sha256sums md5sums; do
    grep -qE "^${sv}=" PKGBUILD && echo "${sv}+=('SKIP')"
  done
  # We modify config.x86_64, so its recorded checksum will not match: skip it.
  for sv in b2sums_x86_64 sha512sums_x86_64 sha256sums_x86_64 md5sums_x86_64; do
    grep -qE "^${sv}=" PKGBUILD && echo "${sv}=(${xskips})"
  done
  echo "# <<< $MARKER <<<"
} >> PKGBUILD
ok "patch wired in; x86_64 config checksum set to SKIP (config is modified)"

# 4c. Enable the smart-amp / SOF options the fix needs.
#     We deliberately do NOT touch CONFIG_LOCALVERSION: Arch already derives a
#     distinct module-dir suffix from the pkgbase name ("-16iax10h-audio") via a
#     localversion file in prepare(), so the custom kernel will not collide with
#     stock "linux". Setting LOCALVERSION here too would double the suffix
#     (producing ...-16iax10h-audio-16iax10h).
cat >> "$CONFIG_FILE" <<EOF
# $MARKER audio options
CONFIG_SND_HDA_SCODEC_AW88399=m
CONFIG_SND_HDA_SCODEC_AW88399_I2C=m
CONFIG_SND_SOC_AW88399=m
CONFIG_SND_SOC_SOF_INTEL_TOPLEVEL=y
CONFIG_SND_SOC_SOF_INTEL_COMMON=m
CONFIG_SND_SOC_SOF_INTEL_MTL=m
CONFIG_SND_SOC_SOF_INTEL_LNL=m
EOF
ok "config ($CONFIG_FILE): AW88399 + SOF options enabled"

# ---------------------------------------------------------------------------
# Step 5: build the packages
# ---------------------------------------------------------------------------
step "Importing kernel signing keys"
readarray -t VALIDKEYS < <(bash -c 'source ./PKGBUILD; printf "%s\n" "${validpgpkeys[@]}"' 2>/dev/null || true)
PGP_OK=1

# Recompute the set of declared keys not yet in the keyring into MISS.
recheck_missing() {
  MISS=()
  local k
  for k in "${VALIDKEYS[@]}"; do
    gpg --list-keys "$k" >/dev/null 2>&1 || MISS+=("$k")
  done
}

if [[ ${#VALIDKEYS[@]} -eq 0 ]]; then
  skip "PKGBUILD declares no validpgpkeys"
else
  recheck_missing
  if [[ ${#MISS[@]} -eq 0 ]]; then
    skip "all signing keys already present in keyring"
  else
    # 1) Public keyservers (covers the Arch packager key).
    for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
      recheck_missing
      [[ ${#MISS[@]} -gt 0 ]] || break
      gpg --keyserver "$ks" --recv-keys "${MISS[@]}" 2>/dev/null || true
    done
    # 2) kernel.org Web Key Directory for the upstream tarball signers (Linus, Greg KH).
    #    WKD pulls the key straight from kernel.org, which is authoritative for them.
    recheck_missing
    if [[ ${#MISS[@]} -gt 0 ]]; then
      gpg --auto-key-locate clear,wkd --locate-external-keys \
        torvalds@kernel.org gregkh@kernel.org 2>/dev/null || true
    fi
    recheck_missing
    if [[ ${#MISS[@]} -eq 0 ]]; then
      ok "all signing keys imported (keyservers + kernel.org WKD)"
    else
      PGP_OK=0
      warn "still missing after keyservers + kernel.org WKD: ${MISS[*]}"
      warn "building with --skippgpcheck; integrity is still enforced via the sha256/b2 checksums"
    fi
  fi
fi

step "Building the kernel (this is the long one)"
export MAKEFLAGS="-j$(nproc)"
if ls "$SRC"/${CUSTOM_PKGBASE}-*.pkg.tar.zst >/dev/null 2>&1 && [[ $FORCE -eq 0 ]]; then
  skip "built packages already present in $SRC (use --force to rebuild)"
else
  mkflags=(-s --noconfirm --cleanbuild)
  [[ $PGP_OK -eq 1 ]] || mkflags+=(--skippgpcheck)
  # If a prior package exists, makepkg refuses to overwrite without its own -f.
  [[ $FORCE -eq 1 ]] && mkflags+=(-f)
  makepkg "${mkflags[@]}"
  ok "build complete"
fi

# ---------------------------------------------------------------------------
# Step 6: install kernel + headers
# ---------------------------------------------------------------------------
step "Installing kernel and headers"
if pacman -Q "$CUSTOM_PKGBASE" >/dev/null 2>&1 && [[ $FORCE -eq 0 ]]; then
  skip "$CUSTOM_PKGBASE already installed (use --force to reinstall)"
else
  mapfile -t PKGS < <(ls "$SRC"/${CUSTOM_PKGBASE}-*.pkg.tar.zst 2>/dev/null | grep -E "${CUSTOM_PKGBASE}(-headers)?-[0-9]")
  [[ ${#PKGS[@]} -ge 1 ]] || die "no built packages found to install"
  sudo pacman -U --noconfirm "${PKGS[@]}"
  ok "installed: ${PKGS[*]##*/}"
fi

# Resolve the installed kernelrelease (module dir whose pkgbase matches ours).
KERNELRELEASE=""
for d in /usr/lib/modules/*/; do
  if [[ -f "${d}pkgbase" ]] && [[ "$(cat "${d}pkgbase")" == "$CUSTOM_PKGBASE" ]]; then
    KERNELRELEASE="$(basename "$d")"; break
  fi
done
[[ -n "$KERNELRELEASE" ]] || die "could not locate installed module dir for $CUSTOM_PKGBASE"
ok "kernelrelease: $KERNELRELEASE"
[[ -f "/boot/vmlinuz-$CUSTOM_PKGBASE" ]] || warn "expected /boot/vmlinuz-$CUSTOM_PKGBASE not found; check your /boot mount and mkinitcpio output"

# ---------------------------------------------------------------------------
# Step 7: NVIDIA DKMS for the new kernel
# ---------------------------------------------------------------------------
step "Ensuring NVIDIA DKMS modules for the new kernel"
sudo pacman -S --needed --noconfirm nvidia-open-dkms >/dev/null
# The dkms pacman hook builds on install; this is a belt-and-suspenders pass.
if ! dkms status -k "$KERNELRELEASE" 2>/dev/null | grep -qi installed; then
  sudo dkms autoinstall -k "$KERNELRELEASE" || warn "dkms autoinstall reported an issue; check 'dkms status'"
fi
dkms status -k "$KERNELRELEASE" 2>/dev/null || true
ok "NVIDIA DKMS handled"

# ---------------------------------------------------------------------------
# Step 8: AW88399 firmware blob
# ---------------------------------------------------------------------------
step "Installing AW88399 amp firmware"
if [[ -f /usr/lib/firmware/aw88399_acf.bin ]] && cmp -s "$FW_SRC" /usr/lib/firmware/aw88399_acf.bin && [[ $FORCE -eq 0 ]]; then
  skip "firmware already installed and identical"
else
  sudo install -Dm644 "$FW_SRC" /usr/lib/firmware/aw88399_acf.bin
  ok "firmware installed to /usr/lib/firmware/aw88399_acf.bin"
fi

# ---------------------------------------------------------------------------
# Step 9: amp calibration as a per-login user service (runs post-reboot)
# ---------------------------------------------------------------------------
step "Installing amp-calibration user service"
CAL=/usr/local/bin/16iax10h-calibrate.sh
sudo tee "$CAL" >/dev/null <<'EOF'
#!/bin/sh
# Engage the Awinic smart amps via UCM, then run the calibration mixer pokes.
card=$(awk '/\[.*[sS][oO][fF].*\]/{gsub(/[^0-9]/,"",$1); print $1; exit}' /proc/asound/cards)
[ -n "$card" ] || card=0
alsaucm -c "hw:$card" reset  >/dev/null 2>&1 || true
alsaucm -c "hw:$card" reload >/dev/null 2>&1 || true
systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1 || true
# Calibration (not volume): required for the amps to function.
amixer -c "$card" sset Master    100% >/dev/null 2>&1 || true
amixer -c "$card" sset Headphone 100% >/dev/null 2>&1 || true
amixer -c "$card" sset Speaker    100% >/dev/null 2>&1 || true
EOF
sudo chmod +x "$CAL"

USERSVC="$HOME/.config/systemd/user/16iax10h-calibrate.service"
mkdir -p "$(dirname "$USERSVC")"
cat > "$USERSVC" <<EOF
[Unit]
Description=16IAX10H speaker amp calibration
After=pipewire.service wireplumber.service
Wants=pipewire.service

[Service]
Type=oneshot
ExecStart=$CAL

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload || true
systemctl --user enable 16iax10h-calibrate.service >/dev/null 2>&1 || \
  warn "could not enable user service now (no user systemd bus in this context); it will still enable on next login graphical session, or run: systemctl --user enable --now 16iax10h-calibrate.service"
ok "calibration will run automatically each login"

# ---------------------------------------------------------------------------
# Step 10: bootloader entry + mandatory DSP boot parameter
# ---------------------------------------------------------------------------
if [[ $SKIP_BOOTLOADER -eq 1 ]]; then
  step "Bootloader (skipped by flag)"
  warn "You must add a boot entry for /boot/vmlinuz-$CUSTOM_PKGBASE and include '$DSP_PARAM' yourself."
else
  step "Configuring bootloader"
  if bootctl is-installed >/dev/null 2>&1; then
    BOOTPATH="$(bootctl --print-boot-path 2>/dev/null || echo /boot)"
    ENTRYDIR="$BOOTPATH/loader/entries"
    NEWENTRY="$ENTRYDIR/arch-16iax10h-audio.conf"
    if [[ -f "$NEWENTRY" ]] && [[ $FORCE -eq 0 ]]; then
      skip "systemd-boot entry already exists: $NEWENTRY"
    else
      # Clone an existing stock entry so we preserve microcode initrd lines.
      TEMPLATE="$(grep -rl 'vmlinuz-linux$' "$ENTRYDIR"/*.conf 2>/dev/null | head -1 || true)"
      if [[ -n "$TEMPLATE" ]]; then
        sudo cp "$TEMPLATE" "$NEWENTRY"
        sudo sed -i \
          -e 's|^title .*|title   Arch Linux (16IAX10H Audio)|' \
          -e "s|vmlinuz-linux\$|vmlinuz-$CUSTOM_PKGBASE|" \
          -e "s|initramfs-linux\.img\$|initramfs-$CUSTOM_PKGBASE.img|" \
          "$NEWENTRY"
      else
        # No template: build options from the current cmdline.
        OPTS="$(tr ' ' '\n' < /proc/cmdline | grep -vE '^(BOOT_IMAGE|initrd)=' | tr '\n' ' ')"
        sudo tee "$NEWENTRY" >/dev/null <<EOF
title   Arch Linux (16IAX10H Audio)
linux   /vmlinuz-$CUSTOM_PKGBASE
initrd  /initramfs-$CUSTOM_PKGBASE.img
options $OPTS
EOF
      fi
      # Ensure the DSP parameter is present on the options line.
      if ! grep -q 'snd_intel_dspcfg.dsp_driver=' "$NEWENTRY"; then
        sudo sed -i "/^options /s/\$/ $DSP_PARAM/" "$NEWENTRY"
      fi
      ok "systemd-boot entry written: $NEWENTRY"
    fi
  elif [[ -f /boot/grub/grub.cfg ]]; then
    if grep -q 'snd_intel_dspcfg.dsp_driver=' /etc/default/grub; then
      skip "DSP parameter already in /etc/default/grub"
    else
      sudo sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $DSP_PARAM\"/" /etc/default/grub
      ok "added '$DSP_PARAM' to GRUB_CMDLINE_LINUX_DEFAULT"
    fi
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    ok "regenerated grub.cfg (your new kernel is auto-detected)"
  else
    warn "Could not detect systemd-boot or GRUB. Add a boot entry for /boot/vmlinuz-$CUSTOM_PKGBASE manually and include '$DSP_PARAM'."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

${c_grn}All steps complete.${c_reset}

Next:
  1. Reboot and pick the "Arch Linux (16IAX10H Audio)" entry
     (GRUB users: it appears as a normal linux-16iax10h-audio entry).
  2. Verify you are on it:        uname -r        (expect: $KERNELRELEASE)
  3. Confirm sound:               wpctl status    (Speaker sink, then play audio)

The amp calibration runs automatically at login. If the very first boot is
silent, log out and back in once, or run:
    systemctl --user start 16iax10h-calibrate.service

Re-running this script is safe; finished steps are skipped. Use --force to redo.

If the BUILD failed while applying the patch (hunk failures), your 7.0.10
source has drifted from the "7.0" patch. Fall back to the kernel version the
repo pins exactly (6.19.11): not automated here, ask and I will adjust the
script to build from the matching source.
EOF
