#!/usr/bin/env bash
#
# enable-hibernate-attempt.sh
# Lockout-PROOF hibernate attempt for the Legion Pro 7 16IAX10H (Blackwell + nvidia-open 610).
# Keeps nvidia in early KMS (mandatory on this GPU), clears the nv_pmops_freeze -5 by pinning
# NVreg_PreserveVideoMemoryAllocations=0, and re-adds resume= so a saved image can be restored.
#
# Worst case: hibernate resume fails -> normal fresh boot (you lose that session). NO lockout,
# because early KMS stays intact so the GPU + SDDM + Hyprland always come up on a cold boot.
#
# Run:  sudo bash ~/Arch/enable-hibernate-attempt.sh
#
set -uo pipefail
say(){ printf '\033[1;35m==>\033[0m %s\n' "$*"; }
ok(){  printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; }
bad(){ printf '    \033[0;31m[FAIL]\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m[warn]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo bash $0"; exit 1; }

GRUB=/etc/default/grub
MKI=/etc/mkinitcpio.conf
SWAPFILE=/swap/swapfile

say "0. SAFETY: confirm nvidia is in early KMS (must be, or we abort to avoid a lockout)"
if grep -qE '^MODULES=.*\bnvidia\b' "$MKI"; then
  ok "early KMS intact: $(grep -E '^MODULES=' "$MKI")"
else
  bad "nvidia is NOT in early KMS -- ABORTING (adding hibernate now risks a lockout)."
  echo "    restore it first, then re-run."; exit 1
fi

say "1. Add the modprobe option that clears the freeze -5 (keeps the open kernel-notifier path)"
echo 'options nvidia NVreg_PreserveVideoMemoryAllocations=0' > /etc/modprobe.d/nvidia-hibernate.conf
ok "wrote /etc/modprobe.d/nvidia-hibernate.conf (Preserve=0; UseKernelSuspendNotifiers=1 + /var/tmp already shipped)"

say "2. Recompute the swapfile resume offset (fresh, authoritative) + root UUID"
RUUID="$(findmnt -no UUID /)"
ROFF="$(btrfs inspect-internal map-swapfile -r "$SWAPFILE" 2>/dev/null)"
[ -n "$RUUID" ] && [ -n "$ROFF" ] || { bad "could not get UUID/offset (swapfile missing?)"; exit 1; }
swapon --show=NAME --noheadings | grep -qx "$SWAPFILE" || swapon "$SWAPFILE" 2>/dev/null || true
ok "resume target: UUID=$RUUID  offset=$ROFF"

say "3. Add resume=/resume_offset= to the GRUB cmdline (so a saved image is found on boot)"
if grep -q 'resume=UUID=' "$GRUB"; then
  warn "resume= already present -- updating offset to $ROFF"
  sed -i -E "s|resume=UUID=[0-9a-fA-F-]+ resume_offset=[0-9]+|resume=UUID=$RUUID resume_offset=$ROFF|" "$GRUB"
else
  sed -i "s|\(GRUB_CMDLINE_LINUX_DEFAULT=\"\)|\1resume=UUID=$RUUID resume_offset=$ROFF |" "$GRUB"
fi
grep -q "resume=UUID=$RUUID" "$GRUB" && ok "added resume= to $GRUB" || { bad "resume= edit failed"; exit 1; }

say "4. Ensure the 'resume' initramfs hook is present (after filesystems)"
if grep -qE '^HOOKS=.*\bresume\b' "$MKI"; then
  ok "resume hook already present"
else
  sed -i -E 's/^(HOOKS=.*)\bfilesystems\b/\1filesystems resume/' "$MKI"
  grep -qE '^HOOKS=.*\bresume\b' "$MKI" && ok "added resume hook" || warn "could not add resume hook -- check $MKI"
fi

say "5. Keep the nvidia sleep services DISABLED (open driver no-ops them; enabling aggravates -5)"
systemctl disable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service nvidia-suspend-then-hibernate.service >/dev/null 2>&1 || true
ok "nvidia-suspend/resume/hibernate left disabled (correct for the open driver)"

say "6. Rebuild initramfs + regenerate GRUB"
mkinitcpio -P 2>&1 | grep -iE 'Building|Image gener|ERROR' || warn "check mkinitcpio output above"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | grep -iE 'Found linux|done|error' | tail -4

say "7. FINAL SAFETY RE-CHECK: early KMS still intact after the rebuild?"
if grep -qE '^MODULES=.*\bnvidia\b' "$MKI"; then
  ok "early KMS still intact -- GPU/login are safe on next boot"
else
  bad "early KMS was lost! Do NOT reboot. Restore: run ~/Arch/recover-disable-hibernate.sh"; exit 1
fi

echo
say "DONE. Now:"
say "  1) sudo reboot   (normal boot -- GPU/login are guaranteed to work, early KMS is intact)"
say "  2) after reboot, confirm the param applied:"
say "       sudo grep -iE 'Preserve|Notifier' /proc/driver/nvidia/params"
say "       (expect PreserveVideoMemoryAllocations: 0 , UseKernelSuspendNotifiers: 1)"
say "  3) TEST suspend FIRST (must pass):   systemctl suspend   -> wake, log in"
say "  4) THEN the real test:               sudo systemctl hibernate"
say "       - powers off, then on power-on RESTORES your session  = SUCCESS"
say "       - comes up as a fresh boot (lost session)             = hit the upstream Blackwell bug"
say "REVERT if you want hibernate gone again:  sudo bash ~/Arch/recover-disable-hibernate.sh"
