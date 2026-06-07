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

command -v v4l2-ctl >/dev/null 2>&1 || { say "installing v4l-utils (needed to read the privacy bit)"; $SUDO pacman -S --needed --noconfirm v4l-utils; }

# sanity: is this the expected camera?
if ! lsusb 2>/dev/null | grep -qi '30c9:00f8\|30c9:f8'; then
  warn "camera 30c9:00f8 not found via lsusb -- the guard matches that VID:PID; if your camera differs, edit VID/PID in the script."
fi

say "1. install the guard script"
$SUDO install -m0700 "$SELF/camera-privacy-guard.sh" /usr/local/sbin/camera-privacy-guard.sh
ok "/usr/local/sbin/camera-privacy-guard.sh"

say "2. install + enable the systemd service"
$SUDO install -m0644 "$SELF/camera-privacy-guard.service" /etc/systemd/system/camera-privacy-guard.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now camera-privacy-guard.service
sleep 1
systemctl is-active --quiet camera-privacy-guard.service && ok "service active" || warn "service not active -- check: journalctl -u camera-privacy-guard"

say "3. udev safety-net: re-apply state on replug/resume"
$SUDO tee /etc/udev/rules.d/99-camera-privacy.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="30c9", ATTR{idProduct}=="00f8", RUN+="/bin/systemctl restart camera-privacy-guard.service"
EOF
$SUDO udevadm control --reload-rules
ok "udev rule installed"

say "Done. Test it:"
say "  flip the privacy switch ON  -> within ~1s:  ls /dev/video0   (should say: No such file)"
say "  flip it OFF                  -> /dev/video0 returns"
say "  uninstall:  sudo systemctl disable --now camera-privacy-guard.service && sudo rm /usr/local/sbin/camera-privacy-guard.sh /etc/systemd/system/camera-privacy-guard.service /etc/udev/rules.d/99-camera-privacy.rules"
