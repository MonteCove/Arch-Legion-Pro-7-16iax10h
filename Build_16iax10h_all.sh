#!/usr/bin/env bash
#
# Build_16iax10h_all.sh
# One wrapper for the whole Lenovo Legion Pro 7 16IAX10H setup: run all three
# installers in the correct order, or verify them all at once.
#
#   audio   Build_16iax10h_audio.sh   the speaker-patched kernel (AW88399 + SOF)
#   power   Build_16iax10h_power.sh   legion module + RAPL governor + battery conservation
#   tweaks  Build_16iax10h_tweaks.sh  resume fixes, OLED idle, warm light, firewall, snapshots, ...
#
# Usage:
#   ./Build_16iax10h_all.sh verify         # read-only: run all three --verify, aggregate (no sudo)
#   ./Build_16iax10h_all.sh install        # install all in order (audio -> power -> tweaks)
#   ./Build_16iax10h_all.sh                # same as 'install'
#   ./Build_16iax10h_all.sh install --force # pass --force through to each installer
#
# Order matters on a FRESH install: power/tweaks build the legion DKMS module for
# the kernel you are *running*, so they should run while booted on the audio
# kernel. If you launch 'install' from a non-audio kernel, this builds audio +
# sets it as the GRUB default, then stops and asks you to REBOOT into it and
# re-run 'install' to finish power + tweaks. (DKMS self-heals, so it is not a hard
# requirement -- just the clean path.) Run as your NORMAL user (sub-scripts sudo).
#
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd || echo "$PWD")"
AUDIO="$DIR/Build_16iax10h_audio.sh"
POWER="$DIR/Build_16iax10h_power.sh"
TWEAKS="$DIR/Build_16iax10h_tweaks.sh"

# ---- helpers ----
hdr()  { printf '\n\033[1;36m======== %s ========\033[0m\n' "$*"; }
say()  { printf '\033[1;35m::\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[0;31m[FAIL]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }
usage(){ awk 'NR>1{ if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as your normal user, not root/sudo (the sub-scripts call sudo per-step)." >&2
  exit 1
fi

for s in "$AUDIO" "$POWER" "$TWEAKS"; do
  [ -f "$s" ] || die "missing: $s  (run this from the repo dir)"
  [ -x "$s" ] || chmod +x "$s" 2>/dev/null || die "not executable: $s"
done

on_audio_kernel() { case "$(uname -r)" in *16iax10h-audio) return 0 ;; *) return 1 ;; esac; }

# ---- verify all ----
do_verify_all() {
  local fails=0
  hdr "VERIFY 1/3: audio" ; "$AUDIO"  --verify || fails=$((fails+1))
  hdr "VERIFY 2/3: power" ; "$POWER"  --verify || fails=$((fails+1))
  hdr "VERIFY 3/3: tweaks"; "$TWEAKS" --verify || fails=$((fails+1))
  hdr "OVERALL"
  if [ "$fails" -eq 0 ]; then
    ok "all three verifications passed"
    on_audio_kernel || say "note: you are NOT on the audio kernel ($(uname -r)); boot the '16IAX10H Audio' entry for working speakers"
    return 0
  fi
  bad "$fails of 3 reported problems (scroll up for the [FAIL] lines)"
  return 1
}

# ---- install all (in order) ----
do_install_all() {
  local fflag="${1:-}"
  hdr "INSTALL 1/3: audio (speaker kernel)"
  "$AUDIO" $fflag || die "audio installer failed -- fix the issue and re-run"

  if ! on_audio_kernel; then
    hdr "REBOOT NEEDED (correct-order gate)"
    say "Audio kernel is built and set as the GRUB default, but you are on '$(uname -r)'."
    say "Power + tweaks should build the legion module against the audio kernel, so:"
    say "  1) REBOOT and pick 'Arch Linux (16IAX10H Audio)'"
    say "  2) re-run:  ./$(basename "$0") install   (finishes power + tweaks)"
    say "(If you'd rather not reboot first, DKMS self-heals -- just run"
    say " './Build_16iax10h_power.sh' and './Build_16iax10h_tweaks.sh' by hand now.)"
    return 0
  fi

  hdr "INSTALL 2/3: power (legion + RAPL governor + battery conservation)"
  "$POWER" $fflag || die "power installer failed -- fix the issue and re-run"
  hdr "INSTALL 3/3: tweaks (resume fixes, OLED, warm light, firewall, snapshots)"
  "$TWEAKS" $fflag || die "tweaks installer failed -- fix the issue and re-run"

  hdr "ALL DONE"
  ok "audio + power + tweaks installed on the audio kernel"
  say "Confirm with:  ./$(basename "$0") verify"
  say "A reboot is recommended to settle kernel-module + initramfs changes."
}

# ---- dispatch ----
ACTION="install"; FFLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    verify|--verify) ACTION="verify" ;;
    install)         ACTION="install" ;;
    --force)         FFLAG="--force" ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$ACTION" in
  verify)  do_verify_all; exit $? ;;
  install) do_install_all "$FFLAG"; exit $? ;;
esac
