# EasyEffects — Legion speaker EQ

A tuned audio chain for the small AW88399 laptop speakers, plus a background service so
it runs without a desktop-environment autostart (we're on Hyprland).

`Legion-Speakers.json` chain: **bass_enhancer → 10-band equalizer → loudness → limiter**
- bass lift (32–125 Hz) to give the small drivers low end
- slight 500 Hz dip to cut boxiness; presence/treble lift (2–16 kHz) for clarity
- loudness + limiter so it gets fuller without clipping

## Setup (per-user; no sudo — EasyEffects is a user service)

```bash
sudo pacman -S --needed easyeffects                       # if not already installed
mkdir -p ~/.config/easyeffects/output
cp ~/Arch/dotfiles/easyeffects/Legion-Speakers.json ~/.config/easyeffects/output/

# background service (Hyprland has no DE autostart):
cp ~/Arch/dotfiles/easyeffects/easyeffects.service ~/.config/systemd/user/   # see file below
systemctl --user daemon-reload
systemctl --user enable --now easyeffects.service

# load the preset (EasyEffects 8.2 imports the JSON into its KConfig db/ on load):
easyeffects -l Legion-Speakers
```

After this, audio routes: app → **Easy Effects Sink** → processed → Speaker. Confirm with
`wpctl status` (you'll see "Easy Effects Sink/Source") and just play something.

## Notes
- **EasyEffects 8.2 changed its config format** to KDE `KConfig` files under
  `~/.config/easyeffects/db/*rc` (it depends on `kconfigwidgets`). The portable preset is
  still the JSON above — `easyeffects -l <name>` imports it into the new `db/` format.
- To tweak by ear, open the GUI (`easyeffects`), adjust bands, and it saves live. Re-export
  a JSON from Presets if you want to update the repo copy.
- The service file:

```ini
# ~/.config/systemd/user/easyeffects.service
[Unit]
Description=EasyEffects audio processing (background, Legion speaker EQ)
After=pipewire.service wireplumber.service
Wants=pipewire.service
[Service]
Type=simple
ExecStart=/usr/bin/easyeffects --service-mode
Restart=on-failure
RestartSec=3
[Install]
WantedBy=default.target
```
