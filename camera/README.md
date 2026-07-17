# Camera privacy-switch enforcement

**Problem (verified on-device):** the Legion's camera privacy switch sets the V4L2
`privacy` bit (kernel reads `privacy=1`) but **does not actually stop the camera on Linux** —
captured 5 live frames with the switch ON. It's privacy theater: apps can still see you.

**Why there's no native fix** (researched + verified): `V4L2_CID_PRIVACY` is reporting-only;
`uvcvideo` maps the bit but never halts streaming on it, and there's no module/kernel/quirk
param to make it enforce. Enforcement is the firmware's job, and this Lenovo/Luxvisions
firmware (USB `30c9:00f8`) doesn't do it on Linux. The only real fix is userspace.

**The fix:** a systemd service polls the privacy bit and **unbinds the uvcvideo USB
interface** when the switch is ON — so the camera's `/dev/video*` nodes vanish and any capture
gets `ENODEV` — then rebinds when you flip it OFF. Matched by VID:PID (`30c9:00f8`),
port-independent; the video node is resolved from sysfs (an external webcam can't confuse it).
Verified: both video nodes live on interface `:1.0`, so that interface is what gets unbound.

**Honest limitation:** while the camera is cut, the switch state can only be re-read by
briefly rebinding the device (every `RECHECK`, default 20s) — the camera is technically
openable for the ~0.2–0.4s each re-check takes (~2% duty cycle). Not a perfect hardware
cut-off; it is a strong deterrent plus auto-restore, and the residual window is logged design,
not an accident.

## Install
```bash
cd ~/Arch && ./camera/install-camera-privacy-guard.sh
```
Installs the guard to `/usr/local/sbin`, enables `camera-privacy-guard.service`, and adds a
udev safety-net that re-applies state on replug/resume.

## Test
- Flip the privacy switch **ON** → within ~10s (`POLL`) the camera's `/dev/video*` nodes vanish.
- Flip it **OFF** → within ~20s (`RECHECK`) they return; camera works again.

## Notes / tuning
- `CAM_GUARD_POLL` (default 10s): switch check while the camera is usable. `CAM_GUARD_RECHECK`
  (default 20s): re-check cadence while cut. Lower = faster reaction; the old 1s poll kept the
  webcam USB device from ever autosuspending (~0.3–0.6 W) and hammered udev with rebinds.
- Failure policy: if the privacy bit can't be read 3× in a row (e.g. v4l-utils removed), the
  guard **cuts the camera (fail closed)** and logs why to the journal.
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
