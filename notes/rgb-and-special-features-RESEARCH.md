All confirmed. Note a nuance worth flagging: the survey said the lighting controller is 048d:c193 (hidraw1/hidraw2), but the working community tool drives 048d:c197 (hidraw3) via HID feature reports — same physical ITE 8258, different USB interface. The tool's author tested on this exact board, so c197 is correct for the per-key path; c193 is a secondary interface. Root is btrfs `@` (no LUKS) → the TPM-unlock item must be dropped. NPU has a real Level Zero / compute-runtime stack in `extra` (no AUR needed).

I now have everything needed. Here is the briefing.

---

# Legion Pro 7 16IAX10H — RGB + Special Features (research briefing)

> Machine: Lenovo Legion Pro 7 16IAX10H (DMI **83F5**, board LNVNB161216, BIOS Q7CN77WW). Core Ultra 9 275HX (Arrow Lake-HX), RTX 5080 Max-Q (nvidia-open 610), Arch + Hyprland/Wayland, kernel 7.0.x, legion-laptop (gluceri fork) on VPC2004.
> All commands are run-as-user-with-sudo. **vim, never nano.** AUR packages are flagged. Confidence tags: **[VERIFIED-LIVE]** = checked on your hardware this session; **[VERIFIED-WEB]** = corroborated by a cited source; **[UNCONFIRMED — test first]** = plausible but not proven on this exact board.

---

## 1. Keyboard RGB / lighting — how to control colors

### The single most important fact: your keyboard is **per-key Spectrum**, not 4-zone.
Your keyboard is the **ITE 8258 "Spectrum"** controller — `048d:c197`, the `ITE Device(8258)` on `/dev/hidraw3` **[VERIFIED-LIVE]**. The 16IAX10H (Gen 10, 2025) ships with **per-key RGB (101 individually addressable keys)**, confirmed by Lenovo's own spec sheet and retail listings ([psref datasheet](https://psrefstuff.lenovo.com/syspool/Sys/PDF/datasheet/Legion_Pro_7_16IAX10H_Datasheet_EN%20.pdf), [Amazon 16IAX10 listing "Per-Key RGB"](https://www.amazon.com/Lenovo-16IAX10-2560x1600-Display240-GeForce/dp/B0G1RM65XT)) **[VERIFIED-WEB]**.

**This rules out the tools you'll find first in a search.** `l5p-kbl`, `4JX/L5P-Keyboard-RGB`, `FardinAhmed3/Legion-RGB`, and `LegionAura` are all **4-zone** drivers for the 2020–2024 lineup. They will either do nothing or only give you 4 crude zones on your per-key board — **do not use them here.** ([L5P-Keyboard-RGB is explicitly "4 zone … 2020–2024"](https://github.com/4JX/L5P-Keyboard-RGB); [LegionAura is "4-zone"](https://github.com/nivedck/LegionAura)) **[VERIFIED-WEB]**

> Note on the `048d:c193` "Lenovo Lighting" interface (hidraw1/hidraw2) that the earlier survey flagged: that's a secondary HID interface of the same ITE chip. The working per-key path is the **c197** interface via HID *feature reports* — that's what the recommended tool below drives. **[VERIFIED-LIVE]** the c197 device is present on hidraw3.

### Recommended tool: `alstergee/legion-spectrum-control`
This is a community tool **explicitly built and tested on the Legion Pro 7 16IAX10H (83F5, Arrow Lake)** — your exact board. It does **per-key keyboard + the 28 perimeter accent LEDs + the lid LEGION logo**, talks to `048d:c197` over HID feature reports, and is **pure Python 3 stdlib (no dependencies)** ([repo](https://github.com/alstergee/legion-spectrum-control)) **[VERIFIED-WEB]**.

> Status: this is a **small, single-author GitHub project (not in any repo, not even AUR)** — clone-from-source. It is the *only* tool with confirmed Gen-10 per-key support, so it's the right call, but **read `spectrum-ctl.py` before running** (you're piping HID feature reports to your keyboard EC). Treat the exact CLI sub-syntax as **[UNCONFIRMED — test first]**: I've quoted it from the README but the project is new; verify with `--help` after install.

**Install (user + sudo, idempotent):**
```bash
sudo install -d -o root -g root /opt
sudo git clone https://github.com/alstergee/legion-spectrum-control.git /opt/legion-spectrum-control \
  || sudo git -C /opt/legion-spectrum-control pull --ff-only
sudo ln -sf /opt/legion-spectrum-control/spectrum-ctl.py /usr/local/bin/spectrum-ctl
```

**Set a solid color (whole keyboard):**
```bash
sudo spectrum-ctl preset static keyboard red
```

**Set perimeter + logo to one color:**
```bash
sudo spectrum-ctl multi perimeter:static:blue logo:static:blue
```

**Set an effect** (effects: `static, rainbow-wave, screw-rainbow, color-change, color-pulse, color-wave, smooth, rain, ripple, type`):
```bash
sudo spectrum-ctl preset rainbow-wave keyboard --speed 2 --dir right
# multi-zone example:
sudo spectrum-ctl multi keyboard:rainbow-wave: perimeter:color-pulse:purple,cyan
```

**Run without `sudo` (udev rule — the README omits this, so here's a correct one for your device) [UNCONFIRMED — test first]:**
```bash
# group 'plugdev' must exist and contain you:
getent group plugdev >/dev/null || sudo groupadd plugdev
sudo usermod -aG plugdev "$USER"          # log out/in afterward for group to apply

sudo tee /etc/udev/rules.d/60-legion-spectrum.rules >/dev/null <<'EOF'
# Lenovo Legion Spectrum keyboard (ITE 8258) — hidraw access for RGB control
KERNEL=="hidraw*", ATTRS{idVendor}=="048d", ATTRS{idProduct}=="c197", MODE="0660", GROUP="plugdev"
KERNEL=="hidraw*", ATTRS{idVendor}=="048d", ATTRS{idProduct}=="c193", MODE="0660", GROUP="plugdev"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```
After this, drop the `sudo` from the `spectrum-ctl` commands. If it still needs root, the tool is writing the c197 interface that the kernel HID driver also holds — in that case keep `sudo` (simplest) or run via the systemd unit below.

**Persist your color/effect at boot/login (systemd, applies once at startup):**
```bash
sudo tee /etc/systemd/system/legion-rgb.service >/dev/null <<'EOF'
[Unit]
Description=Restore Legion Spectrum RGB
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/spectrum-ctl preset static keyboard red
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now legion-rgb.service
```
Edit the `ExecStart=` line to your preferred command: `sudo systemctl edit --full legion-rgb.service` (opens in your `$EDITOR` — set it to vim). The repo also ships a `spectrum-web.service` web-UI if you want a browser picker instead.

### Chassis light-bar (`ZEPHYR Idea5003`, `17ef:f006`, hidraw0)
This is a **separate Lenovo HID** (the front light-bar / chassis lighting) **[VERIFIED-LIVE]**. The spectrum-control tool's "perimeter" zone targets the keyboard-deck perimeter LEDs via the ITE chip, **not** necessarily this `17ef:f006` device. There is **no known open-source driver for `17ef:f006`** — treat the front light-bar as **[UNCONFIRMED]**; if the perimeter command above doesn't light it, it's BIOS/Vantage-controlled and not currently scriptable on Linux. Don't spend long on it.

### Fallback if the above is flaky: **OpenRGB** (in `extra`)
OpenRGB is **not installed** but **is in the `extra` repo (`openrgb 1.0rc2-6`)** **[VERIFIED-LIVE]**. There is **no confirmed OpenRGB device entry for the Gen-10 per-key `048d:c197`** as of now (the tracker has older 4-zone Legions, not this one) ([OpenRGB devices](https://openrgb.org/devices.html), [Legion 7i 2024 request](https://gitlab.com/CalcProgrammer1/OpenRGB/-/work_items/4220)) **[VERIFIED-WEB]**. So OpenRGB is a *diagnostic* fallback, not a primary path:
```bash
sudo pacman -S --needed openrgb
openrgb --list-devices        # see if it even detects the ITE controller
```
If it lists your keyboard, great; if not (likely), stick with `legion-spectrum-control`.

---

## 2. Worth enabling / configuring (real Linux wins)

Ordered by value.

### A. GPU cTGP / PPAB power lever — **highest-value unused knob** **[VERIFIED-LIVE]**
You drive the CPU via MMIO-RAPL, but the **GPU** power limits on VPC2004 are live, writable, and currently conservative:
```
gpu_ctgp_powerlimit = 80   (W)   gpu_ppab_powerlimit = 15
issupportgpuoc = 5   isacfitforoc = 0   issupportcpuoc = 0
```
Raising `gpu_ctgp_powerlimit` raises the **sustained** GPU board power (the RTX 5080 Max-Q can take more than 80 W on AC), which is free performance in GPU-bound games/compute.

> **Correction vs the original survey:** `isacfitforoc` now reads **0** (it was 1 at survey time). This flag tracks whether the AC adapter is currently delivering enough for OC — it's **dynamic**, gated on the charger. Writes to the GPU power nodes may be **clamped or rejected while it's 0**. Confirm it flips to `1` on the original Lenovo 400 W+ PSU before relying on a higher value. **[VERIFIED-LIVE]**

Test interactively first (note the path, then write):
```bash
GPU=/sys/devices/pci0000:00/0000:00:1f.0/PNP0C09:00/VPC2004:00
cat $GPU/gpu_ctgp_powerlimit $GPU/isacfitforoc          # baseline; want isacfitforoc=1
echo 100 | sudo tee $GPU/gpu_ctgp_powerlimit            # try +20W; watch nvidia-smi power.draw under load
```
If it sticks and is stable under a GPU stress run, persist it with a systemd oneshot (mirror the pattern in §1). **Ramp gradually (80→90→100…), watch temps and `nvidia-smi`, and back off on any instability.** Confidence: nodes are real and writable **[VERIFIED-LIVE]**; the safe ceiling for *your* cooling is **[UNCONFIRMED — test first]**.

### B. Intel NPU (Arrow Lake VPU) stack — **real, and the userspace is in `extra`** **[VERIFIED-LIVE]**
`intel_vpu` is loaded and `/dev/accel/accel0` exists. The Level Zero runtime it needs is in the official repo (no AUR):
```bash
sudo pacman -S --needed level-zero-loader intel-compute-runtime
```
What it's *for*: OpenVINO inference offload (background-blur, local LLM/vision accel, Whisper-style audio). **OpenVINO itself is not in the Arch repos** — you'd get it via `pip install openvino` in a venv or the AUR `python-openvino` (**AUR — flag**). Realistically a niche win unless you run OpenVINO workloads; the *driver* is already working, so there's nothing to "fix," only an SDK to add when you have a use. Confidence: stack present **[VERIFIED-LIVE]**; usefulness depends entirely on your workload.

### C. Audio EQ via **EasyEffects** (ALC287 + dual AW88399 over SOF) **[VERIFIED-LIVE]**
There's **no Linux equivalent of Nahimic/Dolby**, and **no special ALC287 "amp modes" exposed** — the codecs present are just ALC287 + the two HDMI codecs **[VERIFIED-LIVE]**. The realistic win is a parametric EQ on top of PipeWire (you're on PipeWire 1.6.6). EasyEffects is **not installed**:
```bash
sudo pacman -S --needed easyeffects
systemctl --user enable --now easyeffects   # autostart the service for your session
```
Use it for EQ/loudness/crossfeed; load a community preset for the AW88399 laptop speakers if you find one. Pure quality-of-life. **[VERIFIED-LIVE that it's absent + in repo]**

### D. Thunderbolt 4 / USB4 — already 90% there, just authorize devices **[VERIFIED-LIVE]**
`boltctl` is installed, `domain0` + device `0-0` present. There's no `usb4` *bus class* node, which is normal — `bolt` is the management layer. Nothing to install. When you plug a TB4 dock/SSD:
```bash
boltctl list
boltctl enroll <UUID> --policy auto     # trust + auto-authorize on future plug-in
```
Confidence: **[VERIFIED-LIVE]** bolt + domain present.

### ~~E. TPM-backed LUKS unlock~~ — **DROPPED (does not apply)**
The original survey suggested TPM2 LUKS auto-unlock. **Your root is plain btrfs on `/dev/nvme1n1p2[/@]` — there is no LUKS container** **[VERIFIED-LIVE]**. So there's nothing to TPM-unlock. TPM2 (`/dev/tpm0`, v2.0) is present and Secure Boot is off, but **measured boot / TPM unlock only makes sense if you first encrypt the disk** — that's a full reinstall-or-in-place-encrypt project, out of scope here. Omitting per the "drop anything wrong" rule.

---

## 3. Know-about but optional / situational

- **`rapidcharge=1`** **[VERIFIED-LIVE]** — Rapid Charge is already on. It's mutually exclusive with your ~80% conservation cap (already handled); leave as-is. Toggle path if ever needed: `$GPU/rapidcharge` (1=fast charge, conservation auto-off).
- **`winkey=1`** **[VERIFIED-LIVE]** — Super/Win key is enabled. To *disable* it (e.g. to stop accidental presses in-game): `echo 0 | sudo tee $GPU/winkey`. Idempotent, harmless.
- **`touchpad=1`** **[VERIFIED-LIVE]** — touchpad enable/disable via `$GPU/touchpad`. You likely already have Fn-toggle; this is the sysfs backstop.
- **Wake-on-LAN** — you have an Intel `igc` NIC (`enp129s0`) with LED nodes **[VERIFIED-LIVE]**. If you want WoL: `sudo ethtool -s enp129s0 wol g` (persist via a systemd unit or `udev`). Situational; only if you wake this box remotely.
- **`platform_profile`** = `quiet / balanced / performance`, currently `balanced` **[VERIFIED-LIVE]**. Already wired to Fn-Q (handled). Mentioned only so you know `performance` is the profile to pair with the §2A GPU power bump for max sustained output.
- **CPU undervolt caveat** — `issupportcpuoc=0` **[VERIFIED-LIVE]**, and Arrow Lake-HX + modern BIOS almost always **lock the undervolt MSRs (Plundervolt mitigation)**. Don't chase `intel-undervolt`/MSR offsets; they'll silently no-op. Your MMIO-RAPL power tuning is the right and already-done lever. **[VERIFIED-WEB general / VERIFIED-LIVE the flag]**

---

## 4. BIOS-only / not a Linux software fix

Don't burn time trying to script these:

- **MUX switch / dGPU-only mode & G-Sync** — **[VERIFIED-LIVE]** no `gsync` sysfs node, no MUX node. On Legion this is **BIOS-only** (set in BIOS → Display/Hybrid, or it's auto). G-Sync on the internal panel typically requires dGPU-only mode set in BIOS. Not changeable from Linux userspace.
- **XMP / memory OC** — BIOS only.
- **CPU OC** — `issupportcpuoc=0` **[VERIFIED-LIVE]**; the platform reports CPU OC unsupported. Don't try.
- **HDR on the OLED** — Wayland HDR is still maturing; Hyprland HDR support is partial/experimental. Treat as "not reliably there yet," not a config you're missing.
- **Lenovo Vantage / Spectrum-only animations** — the fancy per-app lighting profiles and any front-light-bar (`17ef:f006`) effects are Windows-Vantage features; partial/none on Linux (see §1).
- **Fingerprint reader / SD reader / ambient light sensor** — **none present** **[VERIFIED-LIVE]** (no fp device, no mmc host, no iio). Nothing to enable.

---

## 5. Leave alone

- **Legion fan PWM auto-point curves** — `legion_hwmon` exposes the full `pwm1..3 auto_point1..10` curve nodes **[VERIFIED-LIVE]**, **but writing them can crash the EC on Q7CN** (per your earlier audit). **Read-only. Do not write `pwm*_auto_point*` or set `pwm*_enable` to manual.** `lockfancontroller=0` — leave it. Fan behavior stays EC-managed via `platform_profile`.
- **The `048d:c193` / hidraw1+hidraw2 "Lenovo Lighting" interface directly** — don't hand-craft raw writes to it; use the vetted `spectrum-ctl` path on c197 instead. Blind HID writes to the lighting MCU risk wedging the controller.
- **Already-handled subsystems — do not re-touch:** AW88399 speakers/SOF, MMIO-RAPL CPU power + Fn-Q governor, battery conservation (SBMC ~80%), OLED screen-sleep, hyprsunset, firewall, snapshots, hibernate (nvidia `Preserve=0` + early KMS), Dynamic Boost (`nvidia-powerd`). Fn-keys + camera are a separate task.

---

### Morning quick-start (the 3 things actually worth doing today)
1. **RGB:** install `legion-spectrum-control` (§1), run `sudo spectrum-ctl preset static keyboard <color>`, then add the udev rule + `legion-rgb.service` to persist. Read the script first; the CLI sub-syntax is new-project, so verify with `--help`.
2. **GPU power:** on the original AC adapter, confirm `isacfitforoc` flips to `1`, then test-bump `gpu_ctgp_powerlimit` 80→100 under load and watch `nvidia-smi` + temps before persisting (§2A).
3. **Audio:** `sudo pacman -S easyeffects` and enable the user service for an EQ (§2C).

**Sources (load-bearing):**
- [alstergee/legion-spectrum-control — Gen-10 per-key tool, tested on 16IAX10H 83F5](https://github.com/alstergee/legion-spectrum-control)
- [Lenovo 16IAX10/16IAX10H per-key RGB spec (Amazon retail listing)](https://www.amazon.com/Lenovo-16IAX10-2560x1600-Display240-GeForce/dp/B0G1RM65XT) · [Lenovo psref datasheet](https://psrefstuff.lenovo.com/syspool/Sys/PDF/datasheet/Legion_Pro_7_16IAX10H_Datasheet_EN%20.pdf)
- [4JX/L5P-Keyboard-RGB — 4-zone, 2020–2024 only (why it's the wrong tool here)](https://github.com/4JX/L5P-Keyboard-RGB) · [nivedck/LegionAura — 4-zone](https://github.com/nivedck/LegionAura)
- [OpenRGB supported devices](https://openrgb.org/devices.html) · [Legion 7i 2024 OpenRGB request (no Gen-10 per-key entry yet)](https://gitlab.com/CalcProgrammer1/OpenRGB/-/work_items/4220)
