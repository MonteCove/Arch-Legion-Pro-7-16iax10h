# Camera privacy-switch enforcement

**Problem (verified on-device):** the Legion's camera privacy switch sets the V4L2
`privacy` bit (kernel reads `privacy=1`) but **does not actually stop the camera on Linux** —
captured 5 live frames with the switch ON. It's privacy theater: apps can still see you.

**Why there's no native fix** (researched + verified): `V4L2_CID_PRIVACY` is reporting-only;
`uvcvideo` maps the bit but never halts streaming on it, and there's no module/kernel/quirk
param to make it enforce. Enforcement is the firmware's job, and this Lenovo/Luxvisions
firmware (USB `30c9:00f8`) doesn't do it on Linux. The only real fix is userspace.

**The fix:** a systemd service polls the privacy bit (~1s) and **unbinds the uvcvideo USB
interface** when the switch is ON — so `/dev/video0`+`/dev/video1` vanish and any capture gets
`ENODEV` — then rebinds when you flip it OFF. Matched by VID:PID (`30c9:00f8`), port-independent.
Verified: both video nodes live on interface `:1.0`, so that interface is what gets unbound.

## Install
```bash
cd ~/Arch && ./camera/install-camera-privacy-guard.sh
```
Installs the guard to `/usr/local/sbin`, enables `camera-privacy-guard.service`, and adds a
udev safety-net that re-applies state on replug/resume.

## Test
- Flip the privacy switch **ON** → within ~1s: `ls /dev/video0` → *No such file* (camera truly off).
- Flip it **OFF** → `/dev/video0` returns; camera works again.

## Notes / tuning
- Poll interval: `CAM_GUARD_POLL` env (default 1s). It's a privacy switch — 1s is plenty.
- Detection is polling, not event-driven: a V4L2 control change emits no udev/kobject event,
  so there's nothing to hook; polling the bit is the reliable path.
- Heavier fallback if interface-unbind ever misbehaves: toggle the whole device via
  `echo 0|1 | sudo tee /sys/bus/usb/devices/3-11/authorized` (slower full re-enumerate).
- Uninstall: `sudo systemctl disable --now camera-privacy-guard.service && sudo rm
  /usr/local/sbin/camera-privacy-guard.sh /etc/systemd/system/camera-privacy-guard.service
  /etc/udev/rules.d/99-camera-privacy.rules`

## Files
| file | role |
|---|---|
| `camera-privacy-guard.sh` | the watcher (poll privacy → unbind/rebind uvcvideo) |
| `camera-privacy-guard.service` | systemd unit (hardened: NoNewPrivileges, ProtectSystem) |
| `install-camera-privacy-guard.sh` | idempotent installer + udev safety-net |
