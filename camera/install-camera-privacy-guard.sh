#!/usr/bin/env bash
# install-camera-privacy-guard.sh — make the camera privacy switch actually block the
# camera (it's reporting-only on Linux otherwise). Idempotent. Run as your normal user.
set -uo pipefail
SELF="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
say(){ printf '\033[1;35m==>\033[0m %s\n' "$*"; }
ok(){  printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m[warn]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] && die "run as your normal user (calls sudo per-step)"
SUDO=sudo

command -v v4l2-ctl >/dev/null 2>&1 || { say "installing v4l-utils (needed to read the privacy bit)"; $SUDO pacman -S --needed --noconfirm v4l-utils || die "pacman failed installing v4l-utils"; }

# sanity: is the expected camera present? (scan sysfs — no lsusb dependency)
found=0
for d in /sys/bus/usb/devices/*/; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor")" = "30c9" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "00f8" ] && { found=1; break; }
done
[ "$found" = 1 ] || warn "camera 30c9:00f8 not found in sysfs -- the guard matches that VID:PID; if your camera differs, edit VID/PID in the script."

say "1. install the guard script"
$SUDO install -m0700 "$SELF/camera-privacy-guard.sh" /usr/local/sbin/camera-privacy-guard.sh \
  || die "install of camera-privacy-guard.sh failed"
ok "/usr/local/sbin/camera-privacy-guard.sh"

say "2. install + enable the systemd service"
$SUDO install -m0644 "$SELF/camera-privacy-guard.service" /etc/systemd/system/camera-privacy-guard.service \
  || die "install of camera-privacy-guard.service failed"
$SUDO systemctl daemon-reload || die "systemctl daemon-reload failed"
$SUDO systemctl enable --now camera-privacy-guard.service || die "could not enable camera-privacy-guard.service"
$SUDO systemctl restart camera-privacy-guard.service || warn "restart failed -- check: journalctl -u camera-privacy-guard"
sleep 1
systemctl is-active --quiet camera-privacy-guard.service && ok "service active" || warn "service not active -- check: journalctl -u camera-privacy-guard"

say "3. udev safety-net: re-apply state on replug/resume"
$SUDO tee /etc/udev/rules.d/99-camera-privacy.rules >/dev/null <<'EOF' || die "could not write udev rule"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="30c9", ATTR{idProduct}=="00f8", RUN+="/bin/systemctl restart --no-block camera-privacy-guard.service"
EOF
$SUDO udevadm control --reload-rules || warn "udevadm reload failed -- rule takes effect after reboot"
ok "udev rule installed"

say "Done. Test it (default check cadence: ON->cut within ~10s, OFF->restore within ~20s):"
say "  flip the privacy switch ON  -> within ~10s the camera's /dev/video* nodes vanish"
say "  flip it OFF                  -> within ~20s they return"
say "  tuning: CAM_GUARD_POLL / CAM_GUARD_RECHECK env in the service (lower = faster, more USB wakeups)"
say "  uninstall:  sudo systemctl disable --now camera-privacy-guard.service && sudo rm /usr/local/sbin/camera-privacy-guard.sh /etc/systemd/system/camera-privacy-guard.service /etc/udev/rules.d/99-camera-privacy.rules"
