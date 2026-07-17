#!/bin/sh
# igpu-session.sh on|off|status — make the NEXT Hyprland session iGPU-only.
#
# Hyprland/Aquamarine opens every GPU at startup, holding /dev/nvidia0 open and
# pinning the RTX 5080 in P8 (~5 W) instead of D3cold (~0.3 W). Setting
# AQ_DRM_DEVICES=/dev/dri/card0 in the uwsm env stops that — the dGPU then
# powers fully off whenever nothing uses it (PRIME render offload still works;
# the app wakes the GPU on demand and it sleeps again after).
#
# TRADE-OFF while enabled: outputs wired to the dGPU — HDMI and its DP —
# cannot light up. USB-C DisplayPort (card0/iGPU: DP-2, DP-3) still works.
# Takes effect at the NEXT login (log out / log back in).
set -u
ENVF="$HOME/.config/uwsm/env"
# AQ_DRM_DEVICES stops aquamarine's KMS side, but GLVND still loads the NVIDIA
# EGL driver while probing vendors, which opens /dev/nvidia0 from the compositor
# and blocks D3cold. A drop-in on the compositor UNIT pins its EGL to Mesa only —
# apps launched in the session are separate units and keep full NVIDIA EGL/Vulkan.
DROPD="$HOME/.config/systemd/user/wayland-wm@hyprland.desktop.service.d"
DROPF="$DROPD/50-igpu-only-egl.conf"

case "${1:-status}" in
  on)
    mkdir -p "$(dirname "$ENVF")" "$DROPD"
    grep -q 'AQ_DRM_DEVICES' "$ENVF" 2>/dev/null \
      || printf '%s\n' 'export AQ_DRM_DEVICES=/dev/dri/card0' >> "$ENVF"
    printf '%s\n' '[Service]' \
      'Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json' > "$DROPF"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "iGPU-only session ENABLED for the next login (log out/in to apply)."
    echo "trade-off until 'off'+relogin: HDMI / dGPU-DP outputs dark; USB-C DP still works."
    ;;
  off)
    [ -f "$ENVF" ] && sed -i '/AQ_DRM_DEVICES/d' "$ENVF"
    rm -f "$DROPF"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "iGPU-only session DISABLED for the next login (log out/in to apply)."
    ;;
  status)
    if grep -q 'AQ_DRM_DEVICES' "$ENVF" 2>/dev/null && [ -f "$DROPF" ]; then
      echo "next login   : iGPU-only (KMS + EGL guards set)"
    elif grep -q 'AQ_DRM_DEVICES' "$ENVF" 2>/dev/null || [ -f "$DROPF" ]; then
      echo "next login   : PARTIAL (one guard missing -- run '$0 on' to set both)"
    else
      echo "next login   : all GPUs"
    fi
    if fuser /dev/nvidia0 >/dev/null 2>&1; then
      echo "this session : dGPU held open (no D3cold)"
    else
      echo "this session : dGPU free ($(cat /sys/bus/pci/devices/0000:02:00.0/power/runtime_status 2>/dev/null))"
    fi
    ;;
  *)
    echo "usage: $0 on|off|status" >&2; exit 2
    ;;
esac
