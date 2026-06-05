#!/usr/bin/env bash
#
# install-rgb-studio.sh — install Legion RGB Studio (the web UI) + optional
# "apply default profile at boot" service. Idempotent. Run as your normal user.
#
# Prereqs: legion-spectrum-control already installed (/usr/local/bin/spectrum-ctl).
#
set -uo pipefail
SELF="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # the repo's rgb/ dir
say(){ printf '\033[1;35m==>\033[0m %s\n' "$*"; }
ok(){  printf '    \033[0;32m[ ok ]\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m[warn]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "run as your normal user (it calls sudo per-step)"
SUDO=sudo
USER_NAME="$(id -un)"

command -v spectrum-ctl >/dev/null 2>&1 || die "spectrum-ctl not found — install legion-spectrum-control first (see notes/rgb-and-special-features-RESEARCH.md)"

say "1. Install the Studio + headless default-applier to /opt"
$SUDO install -d /opt/legion-rgb-studio
$SUDO install -m0755 "$SELF/legion-rgb-studio.py"        /opt/legion-rgb-studio/legion-rgb-studio.py
$SUDO install -m0755 "$SELF/legion-rgb-apply-default.py" /opt/legion-rgb-studio/legion-rgb-apply-default.py
$SUDO ln -sf /opt/legion-rgb-studio/legion-rgb-studio.py /usr/local/bin/legion-rgb-studio
ok "installed; launch with:  sudo legion-rgb-studio  → http://127.0.0.1:5566"

say "2. (optional) sudoers drop-in so the Studio + default service run spectrum-ctl without a password prompt"
# Only spectrum-ctl, only for this user — minimal surface.
SUDOERS=/etc/sudoers.d/legion-rgb
if [ ! -f "$SUDOERS" ]; then
  printf '%s ALL=(root) NOPASSWD: /usr/local/bin/spectrum-ctl\n' "$USER_NAME" | $SUDO tee "$SUDOERS" >/dev/null
  $SUDO chmod 0440 "$SUDOERS"
  $SUDO visudo -cf "$SUDOERS" >/dev/null 2>&1 && ok "sudoers drop-in valid: spectrum-ctl runs without password" \
    || { $SUDO rm -f "$SUDOERS"; warn "sudoers check failed -- removed it; you'll just enter your password normally"; }
else
  ok "sudoers drop-in already present"
fi

say "3. (optional) apply your DEFAULT profile at boot (set the default in the Studio UI first)"
UNIT=/etc/systemd/system/legion-rgb-default.service
$SUDO tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Apply the default Legion RGB profile at boot
After=multi-user.target

[Service]
Type=oneshot
# run as the real user so it reads ~/.config/legion-rgb-studio/profiles.json
User=$USER_NAME
ExecStart=/usr/bin/python /opt/legion-rgb-studio/legion-rgb-apply-default.py
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
$SUDO systemctl daemon-reload
$SUDO systemctl enable legion-rgb-default.service >/dev/null 2>&1 \
  && ok "enabled legion-rgb-default.service (applies your default profile each boot)" \
  || warn "could not enable legion-rgb-default.service"

say "Done."
say "  Open the UI:        sudo legion-rgb-studio   (then browse to http://127.0.0.1:5566)"
say "  Set a default:      in the UI → Profiles → Set Default   (auto-applied next boot)"
say "  Uninstall service:  sudo systemctl disable --now legion-rgb-default.service"
