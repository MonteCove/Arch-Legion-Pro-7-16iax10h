# Legion RGB Studio

A polished, fully-editable **web UI** for the Lenovo Legion Pro 7 16IAX10H per-key RGB
keyboard. It drives the audited [`spectrum-ctl`](https://github.com/alstergee/legion-spectrum-control)
CLI (it does **not** touch HID directly) and adds the thing the bundled tool lacks: a
**profile manager** (save / load / set-boot-default / delete).

![tabs: Per-Key · Effects · Multi-Zone · Profiles · Quick]

## Features
- **Per-Key painter** — click/drag to paint any key the current color; Shift-click to
  multi-select then “Paint Selected”; quick-select **WASD / Arrows / Numpad / F-keys**;
  fill-all; erase. The on-screen keyboard mirrors the real 16IAX10H layout.
- **Effects** — all 12 (static, rainbow-wave, color-pulse, rain, ripple, type, …) with
  speed (1–3) + direction, applied to any zone(s).
- **Multi-Zone** — independent effect/color for keyboard, perimeter, and logo at once.
- **Brightness** (0–9) and **lid logo** on/off.
- **Profiles** — save the current look under a name, load it back, **set one as the boot
  default** (auto-applied at login via a systemd service), delete.
- **Quick presets** — Rainbow / White / All-On / Off / Stealth.
- Colors as picker / hex / R,G,B / named swatches. Live status readout.

## Install
Prereq: `legion-spectrum-control` installed (`/usr/local/bin/spectrum-ctl`). Then:

```bash
cd ~/Arch && ./rgb/install-rgb-studio.sh
```
That installs the app to `/opt/legion-rgb-studio`, symlinks `legion-rgb-studio`, adds a
minimal sudoers drop-in (so `spectrum-ctl` runs without a password prompt — only that one
binary, only for you), and enables an optional boot service that applies your default profile.

## Use
```bash
sudo legion-rgb-studio        # starts the server
# open http://127.0.0.1:5566 in your browser
```
Pick a look in any tab → it applies to the keyboard live. In **Profiles**, name it and Save;
“Set Default” makes it apply automatically at every boot.

## How it works
- Pure Python 3 stdlib (`http.server`, `json`, `subprocess`). No external deps.
- Backend translates UI state → validated `spectrum-ctl` argv (never `shell=True`; colors
  and keycodes are sanitized against known sets). Binds `127.0.0.1` only.
- Profiles live in `~/.config/legion-rgb-studio/profiles.json` (owned by you, even under sudo).
- `legion-rgb-apply-default.py` is the headless boot-time applier used by
  `legion-rgb-default.service`.

## Files
| file | role |
|---|---|
| `legion-rgb-studio.py` | the web app (server + UI) |
| `legion-rgb-apply-default.py` | headless “apply default profile” (boot service) |
| `install-rgb-studio.sh` | idempotent installer (+ sudoers + boot service) |

## Notes
- Run with `sudo` (the underlying `spectrum-ctl` needs it to write the keyboard); the
  sudoers drop-in from the installer removes the repeated password prompt.
- The keyboard is **per-key Spectrum (ITE 8258, `048d:c197`)** — see
  `../notes/rgb-and-special-features-RESEARCH.md` for the hardware background.
