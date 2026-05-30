# Arch Linux setup — Lenovo Legion Pro 7 16IAX10H (2025)

Personal scripts to get a **Lenovo Legion Pro 7 16IAX10H** (model `83F5`, BIOS `Q7CN`,
Intel Core Ultra 9 275HX, RTX 50-series, EC ITE IT5508) fully working on Arch Linux.

Two big things this hardware needs that mainline doesn't handle yet:

1. **Speakers** — the AW88399 smart amps aren't driven by the stock kernel, so internal
   audio is silent/tinny. Fixed with a per-kernel community patch ([sound saga](https://github.com/nadimkobeissi/16iax10h-linux-sound-saga)).
2. **CPU power** — the firmware pins the package to a ~30 W MMIO-RAPL cap, so the 275HX
   crawls at ~1.6 GHz under load. Fixed by driving the Intel MMIO-RAPL limit ourselves,
   tied to the Fn-Q power mode, with a thermal guard.

> These are tailored to **this exact model**. The scripts refuse to run on other machines
> unless forced. Use at your own risk.

---

## Scripts

### `Build_16iax10h_audio.sh`
Builds an audio-patched kernel package from the Arch `linux` PKGBUILD: applies the
16IAX10H sound patch, enables the AW88399 / SOF Kconfig options, sets a distinct
`pkgbase` (`linux-16iax10h-audio`) so it coexists with the stock kernel, and wires up the
bootloader entry with the required `snd_intel_dspcfg.dsp_driver=3` parameter. Idempotent,
with logging, dependency/skip checks, signing-key import, and `--force`.

Boot the resulting **"16IAX10H Audio"** kernel entry to get working speakers.

### `Build_16iax10h_power.sh`
One-shot, idempotent installer for the **power / fan / Fn-Q-mode** solution on a fresh
Arch install. Preflight (model + headers + RAPL) → deps → clone+patch+build the
`legion-laptop` module (bound to `VPC2004`) → install + `depmod` → modprobe/blacklist/
autoload configs → install the governor to `/usr/local/bin/legion-powercap` → enable
`legion-powercapd.service` → activate now (no reboot needed). The governor tool is
embedded, so this script alone reproduces the whole setup.

```bash
./Build_16iax10h_power.sh            # full install (safe to re-run)
./Build_16iax10h_power.sh --verify   # read-only health check (great after a reboot)
./Build_16iax10h_power.sh --force    # re-clone + rebuild everything
```

`--verify` runs 18 checks (module loaded+bound, blacklists effective, `platform_profile`
present, MMIO-RAPL + coretemp present, tool/service/config files, and a functional check
that the live power limit matches the current Fn-Q mode). Exit 0 = healthy, 1 = problem.

### `raise-power-cap.sh`  → installed as `/usr/local/bin/legion-powercap`
The governor / power-cap tool (also embedded in the power installer). Drives the Intel
**MMIO-RAPL** package limit.

```bash
sudo legion-powercap --status            # show current RAPL limits
sudo legion-powercap --sweep             # characterize the sustained ceiling (stepped, thermal-guarded)
sudo legion-powercap --daemon            # governor loop: Fn-Q mode -> power limit + thermal guard + battery cap
sudo legion-powercap --pl1 120 --pl2 150 # set limits directly
sudo legion-powercap --restore           # revert to the stock 30 W limits
```

Governor mapping (Fn-Q mode → sustained PL1): **quiet 45 W / balanced 90 W / performance
130 W** (≈ the measured ~128 W chassis ceiling). Thermal guard throttles ≥ 96 °C and
recovers ≤ 88 °C; on **battery** it caps to 90 W regardless of mode. The CPU's ~105 °C
Tjmax throttle is the hard backstop.

### `systemd/`
- **`legion-powercapd.service`** — the governor daemon unit (current). Runs
  `legion-powercap --daemon`, `Restart=always`, starts at boot.
- `legion-powercap.service` — an older one-shot "apply a fixed limit at boot" unit,
  **superseded** by the daemon. Kept for reference.

---

## Order to run (fresh install)

The two builders are **independent** (audio = speakers/kernel; power = CPU power/fan/Fn-Q), but
run them in this order: **audio → reboot into the audio kernel → power.** The power installer
builds the `legion-laptop` module (via DKMS) for the kernel you're *running*, so you want to be on
the audio kernel when you run it. With DKMS it self-heals for other kernels, so the order is for
cleanliness, not a hard dependency.

```bash
# --- 1. Speakers: build + install the audio-patched kernel (+ its headers) ---
./Build_16iax10h_audio.sh

# --- 2. Make the audio kernel your default boot, then reboot into it ---
grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub || echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot                       # at the menu, pick "Arch Linux (16IAX10H Audio)" once
                                  # (GRUB_DEFAULT=saved + SAVEDEFAULT=true makes that stick)

# --- 3. Confirm you're on it, then verify audio ---
uname -r                          # expect: ...-16iax10h-audio
./Build_16iax10h_audio.sh --verify    # expect: N passed, 0 failed

# --- 4. Power / fan / Fn-Q governor (DKMS-builds legion for the running kernel) ---
./Build_16iax10h_power.sh
./Build_16iax10h_power.sh --verify    # expect: N passed, 0 failed
```

After this, both maintain themselves:
- **Audio** is a separate kernel package — rebuild it with `Build_16iax10h_audio.sh` when a newer
  kernel lands (and a matching patch exists).
- **Power's `legion-laptop` is a DKMS module**, so it auto-rebuilds whenever any kernel's headers
  install (including future audio-kernel rebuilds). Re-run `--verify` to confirm after a rebuild.

Re-run either script any time — both are idempotent and skip completed steps (`--force` redoes everything).

## Notes
- `Build_16iax10h_power.sh` blacklists `ideapad_laptop` (frees the `VPC2004` ACPI device for
  `legion-laptop` and fixes a false Wi-Fi rfkill block); you lose ideapad's conservation-mode
  and some extra Fn keys.
- Run the scripts as your **normal user** (they call `sudo` per step), not via `sudo`.
- Each kernel you want covered must have its matching `*-headers` package installed (the audio
  build installs its own; for stock/zen, `sudo pacman -S --needed linux-headers`/`linux-zen-headers`).
- `--verify` on either script is read-only and needs no `sudo` — handy as a quick post-reboot or
  post-update health check.
