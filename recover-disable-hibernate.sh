#!/usr/bin/env bash
#
# recover-disable-hibernate.sh
# Fully undo the hibernate setup that locked the system out, returning boot config
# to the last known-good state (nvidia early-KMS + no resume=). Run with:
#     sudo bash ~/Arch/recover-disable-hibernate.sh
#
set -uo pipefail
say(){ printf '\033[1;35m==>\033[0m %s\n' "$*"; }
ok(){  printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m[warn]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo bash $0"; exit 1; }

GRUB=/etc/default/grub
MKI=/etc/mkinitcpio.conf
BAK=/etc/mkinitcpio.conf.bak-pre-nvidia-hibernate

say "1. Remove resume= from the GRUB cmdline (stops every boot from trying to resume)"
if grep -q 'resume=UUID=' "$GRUB"; then
  cp "$GRUB" "$GRUB.bak-recover"
  sed -i -E 's/ ?resume=UUID=[0-9a-fA-F-]+ ?resume_offset=[0-9]+ ?/ /' "$GRUB"
  grep -q 'resume=' "$GRUB" && warn "resume= still present -- check $GRUB by hand (vim)" || ok "removed resume= / resume_offset= from $GRUB"
else
  ok "no resume= in $GRUB already"
fi

say "2. Restore the pre-hibernate initramfs config (puts nvidia back in early KMS, the known-good setup)"
if [ -f "$BAK" ]; then
  say "   backup is from $(date -r "$BAK" '+%Y-%m-%d %H:%M') -- changes made to $MKI since then are discarded:"
  diff -u "$BAK" "$MKI" | sed 's/^/      /' || true
  cp "$MKI" "$MKI.bak-hibernate-state"
  cp "$BAK" "$MKI"
  ok "restored $MKI from $BAK (previous state kept at $MKI.bak-hibernate-state)"
  grep -E '^MODULES=|^HOOKS=' "$MKI" | sed 's/^/      /'
else
  warn "backup $BAK missing -- ensuring nvidia is in early KMS + dropping resume hook manually"
  grep -qE '^MODULES=.*nvidia' "$MKI" || sed -i -E 's/^MODULES=\(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' "$MKI"
  grep -qE '^HOOKS=.*\bkms\b' "$MKI" || sed -i -E '/^HOOKS=/ s/\bmodconf\b/modconf kms/' "$MKI"
fi
# the 'resume' initramfs hook is harmless without resume= on the cmdline, but the
# restored backup already lacks it on the original line -- leave whatever the backup has.

say "3. Remove the hibernate sleep/lid drop-ins (so lid/idle never try to hibernate again)"
for f in /etc/systemd/sleep.conf.d/10-16iax10h.conf /etc/systemd/logind.conf.d/10-16iax10h.conf; do
  [ -f "$f" ] && { rm -f "$f"; ok "removed $f"; } || ok "already gone: $f"
done

say "4. Keep the swapfile as plain swap (harmless), but it is NO LONGER a resume target"
ok "swap stays active: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
warn "to also remove the 36G swapfile entirely: swapoff /swap/swapfile && sed -i '\\|/swap/swapfile|d' /etc/fstab && btrfs subvolume delete /swap"

say "5. Rebuild initramfs + regenerate GRUB (hard-fail: this IS the recovery -- a silent failure defeats it)"
MKOUT="$(mktemp)"
if mkinitcpio -P >"$MKOUT" 2>&1; then
  grep -iE 'Image gener' "$MKOUT" | tail -3
  ok "initramfs rebuilt"
else
  tail -20 "$MKOUT"
  printf '\033[0;31m!!! mkinitcpio FAILED -- recovery is NOT complete; the current initramfs is unchanged. Fix the error above and re-run.\033[0m\n'
  rm -f "$MKOUT"; exit 1
fi
rm -f "$MKOUT"
GROUT="$(mktemp)"
if grub-mkconfig -o /boot/grub/grub.cfg >"$GROUT" 2>&1; then
  grep -iE 'Found linux' "$GROUT" | tail -3
  ok "grub.cfg regenerated"
else
  tail -10 "$GROUT"
  printf '\033[0;31m!!! grub-mkconfig FAILED -- recovery is NOT complete; grub.cfg may still carry resume=. Fix and re-run.\033[0m\n'
  rm -f "$GROUT"; exit 1
fi
rm -f "$GROUT"

say "6. (battery-guard is safe) it auto-detects no resume= and will cleanly POWER OFF at 5% instead of hibernating"
ok "no action needed -- 16iax10h-battery-guard.sh already falls back to poweroff when resume= is absent"

echo
say "DONE. Reboot normally (no special cmdline needed):  sudo reboot"
say "After reboot you should land at the SDDM login screen again. If the greeter STILL"
say "crashes, that is a separate issue -- boot once more with 'systemd.unit=multi-user.target',"
say "log in on the TTY, and check:  journalctl -b -u sddm  (greeter crashes log there)"
