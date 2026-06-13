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

## Prerequisites — do this FIRST (before any script)

This setup assumes the **[JaKooLit Arch-Hyprland](https://github.com/JaKooLit/Arch-Hyprland)** dotfiles
as the desktop base. Install that first, then make the changes below; the `Build_16iax10h_*` scripts
build on top of it.

> 📦 **Every package these scripts install — what it's for, which script installs it, and a single
> "install everything" command — is documented in [PACKAGES.md](PACKAGES.md).** (All official-repo; no
> AUR needed. You don't install them by hand — the scripts do — but it's a useful reference.)

1. **Install JaKooLit's Arch-Hyprland** and reboot into the Hyprland session.

2. **Wire up the `awww` wallpaper daemon** (an OLED-friendly `swww` fork). Start it once, then
   symlink it so JaKooLit's `swww`/`swww-daemon` wallpaper scripts use it:
   ```bash
   awww-daemon > /dev/null 2>&1 &
   sudo ln -sf /usr/bin/awww /usr/bin/swww && sudo ln -sf /usr/bin/awww-daemon /usr/bin/swww-daemon
   ```

3. **Replace two JaKooLit configs with the versions in this repo** (under `dotfiles/hypr/configs/`):
   ```bash
   cp dotfiles/hypr/configs/SystemSettings.conf ~/.config/hypr/configs/SystemSettings.conf
   cp dotfiles/hypr/configs/Keybinds.conf       ~/.config/hypr/configs/Keybinds.conf
   hyprctl reload     # or relog
   ```
   (The `display` module of `Build_16iax10h_tweaks.sh` later layers a small `16iax10h-user.conf`
   drop-in on top of these — `vrr = 0` for the OLED + `hyprsunset 3000K` — sourced *after* them so it
   wins. It also masks the duplicate `swaync.service`.)

Once JaKooLit is in and those three steps are done, continue with **"Order to run"** below.

4. *(optional)* **Waybar battery — show time remaining inline.** JaKooLit's battery widget shows only
   the percentage by default (time is hidden behind a click). `dotfiles/waybar/battery-module.jsonc`
   has the tweaked `"battery"` block (adds `format-discharging`/`format-charging` with `· {time}`).
   Paste it over the `"battery": { … }` block in `~/.config/waybar/Modules` (edit with vim), then
   reload Waybar (`killall -SIGUSR2 waybar`). On battery it then reads e.g. `󰂁 79% · 3h12m`. Note:
   while plugged in and *holding* at the conservation cap (`Not charging`), there is no time to show.

---

## Scripts

### `Build_16iax10h_all.sh`  ← start here
One wrapper that installs (or verifies) **all three** installers in the correct order.

```bash
./Build_16iax10h_all.sh verify    # run all three --verify and aggregate (read-only, no sudo)
./Build_16iax10h_all.sh install   # install audio -> power -> tweaks, in order
```

If you launch `install` from a **non-audio** kernel it builds the audio kernel, sets it as the GRUB
default, then asks you to reboot into it and re-run `install` to finish power + tweaks (so the legion
DKMS module builds against the audio kernel). On a machine already on the audio kernel it just runs all
three idempotently. The three installers below can also be run individually.

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

**Battery conservation (charge limit):** the installer also patches the legion driver to add a
`conservation_mode` sysfs and installs `legion-conservation.service`, which caps charging
(~60-80 %) at boot to protect the cell. DSDT-verified: `SBMC 0x03` → on / `0x05` → off, status
`GBMD & 0x20` (patch in `patches/legion-conservation-block.c`). It also corrects the driver's
`SBMC`/`GBMD` ACPI path (broken by the `VPC2004` rebind), which revives `rapidcharge`.

> ### ⚡ Charging stops at ~80 %? **That's normal — it's this feature working.**
> With conservation mode **on** (the default), the laptop charges to roughly **80 %** and then
> **stops on purpose** — the battery will read **`Not charging` and hold at ~79-80 %** while plugged
> in. It will **not** top off to 100 %. This is intentional: keeping a lithium battery pinned at
> 100 % on AC is what wears it out fastest, so capping at ~80 % greatly extends its lifespan.
> Nothing is broken.
>
> Side effect: while it's *holding* at the cap (plugged in, `Not charging`), the Waybar battery
> widget shows **no time estimate** — there's no charge/discharge happening, so there's nothing to
> estimate. The time-to-empty appears as soon as you unplug.

**When you want a full 100 % charge** (e.g. before travelling unplugged):

```bash
echo 0 | sudo tee /sys/bus/platform/devices/VPC2004:00/conservation_mode   # lift the cap -> charges to 100%
echo 1 | sudo tee /sys/bus/platform/devices/VPC2004:00/conservation_mode   # re-apply the ~80% cap
```

The cap is **re-enabled automatically on every boot** by `legion-conservation.service`, so an `echo 0`
only lasts until the next reboot. To make 100 % the permanent default instead:

```bash
sudo systemctl disable --now legion-conservation.service   # stop capping; charge to 100% from now on
```

Or set `LEGION_CONSERVATION=0 ./Build_16iax10h_power.sh` to install it but leave the cap off by default.

**Handy aliases** ([`dotfiles/zsh/aliases.zsh`](dotfiles/zsh/aliases.zsh)) — `source` it from `~/.zshrc`:
`charge100` (charge to 100% until next reboot), `chargecap` (re-apply the ~80% cap),
`chargestatus` (show cap + battery %), plus `soff`/`son` (OLED screen off/on).

### `Build_16iax10h_tweaks.sh`
One idempotent, modular **"fixes & features"** installer for everything an audit turned up
*after* the audio + power basics. It runs a set of named **modules** (with no args it runs the
default set); each is logged, error-checked and skip-on-done. Built and vetted via a hardware
audit + an adversarial code review.

```bash
./Build_16iax10h_tweaks.sh            # run the default module set (safe to re-run)
./Build_16iax10h_tweaks.sh --list     # list modules
./Build_16iax10h_tweaks.sh --verify   # read-only health check (no sudo)
./Build_16iax10h_tweaks.sh resume-audio resume-power   # run only these
./Build_16iax10h_tweaks.sh all        # include the opt-in module (spd5118)
```

Modules:
- **resume-audio** *(fix)* — `systemd-sleep` hook that re-binds the AW88399 smart-amps on resume;
  without it the DSP firmware fails its CRC check after S3 and the **speakers go silent until reboot**.
- **resume-power** *(fix)* — `systemd-sleep` hook that re-applies the MMIO-RAPL cap on resume;
  `legion-powercapd` only writes on a mode change, so S3 could otherwise **drop the cap to the
  BIOS ~30 W default**.
- **cpu-governor** — `cpupower` `performance` → `powersave` (dynamic HWP; still full turbo under
  load, gentler on battery).
- **snapshots** — `snapper` + `snap-pac` + `grub-btrfs` → bootable Btrfs rollback per pacman txn.
- **btrfs-scrub / zram / suspend-deep** — monthly scrub timer, grow zram toward RAM, pin `deep`/S3.
- **hibernate** — true hibernation (save session to disk, power off, restore on power-on). 36 GB btrfs
  swapfile on a dedicated `/swap` subvol + `resume=` + the `resume` initramfs hook, and — the part that
  took some doing — it clears the NVIDIA `nv_pmops_freeze -5` by writing
  `/etc/modprobe.d/nvidia-hibernate.conf` (`NVreg_PreserveVideoMemoryAllocations=0`) **while keeping
  nvidia in early KMS**. ⚠️ Early KMS is *mandatory* on this GPU — removing it bricks the display and
  locks you out; this module never touches `MODULES=`. **Verified working** (2026-05-31, kernel 7.0.10
  + nvidia-open 610.43.02): full hibernate/resume restored the session with no `-5` and no GPU Xid.
  If a future kernel/driver regresses resume, `recover-disable-hibernate.sh` reverts it cleanly.
- **battery-guard** — low-battery desktop warnings (with time-left estimate) + auto-action at 5 %
  (hibernate if available, else clean poweroff) — so the laptop can't silently die on battery again.
- **video-accel / gpu-offload / thunderbolt / firmware** — `intel-media-driver` (iGPU HW decode),
  `nvidia-prime` (`prime-run`), `bolt`, the `fwupd-refresh` timer.
- **firewall** — nftables default-deny-inbound host firewall (allows established/related, loopback,
  ICMP/IPv6-NDP, mDNS, and DHCP, so Wi-Fi and `.local` discovery keep working). The ruleset is
  validated with `nft -c` before the service is enabled, so a bad edit can't lock the box down.
- **display** — OLED screen-sleep + warm light. Installs `hypridle`/`hyprlock`/`hyprsunset` and
  deploys `dotfiles/hypr/hypridle.conf` (dim 2.5m → panel **off** 3m → lock 5m → suspend 15m — true
  black protects OLED from burn-in). Also deploys `dotfiles/hypr/16iax10h-user.conf` (a sourced
  drop-in) for **Super+L → lock** and **hyprsunset 3000K**, and toggles warm light with **Super+N** /
  the Waybar sun. Re-deploys the repo copies, backing up the originals — so edit the repo copy (or
  re-sync) and the repo stays canonical.
- **nvidia-powerd** — NVIDIA Dynamic Boost; **auto-masks itself** if the BIOS lacks NVPCF.
- **battery-info** *(read-only)* — reports battery wear + charge-limit availability.
- **spd5118** *(opt-in)* — blacklist the redundant DIMM temp sensor to silence a benign resume error.

It deliberately does **not** touch two things the audit proved unsafe on this EC: battery
charge-limit / conservation EC writes (no working interface exists on this model), and the fan
pwm curve (writing it can crash the EC / stop the fans on Q7CN).

### `systemd/`
- **`legion-powercapd.service`** — the governor daemon unit (current). Runs
  `legion-powercap --daemon`, `Restart=always`, starts at boot.
- `legion-powercap.service` — an older one-shot "apply a fixed limit at boot" unit,
  **superseded** by the daemon. Kept for reference.

---

## Order to run (fresh install)

> **First** complete the **[Prerequisites](#prerequisites--do-this-first-before-any-script)** above
> (install JaKooLit, wire up `awww`, drop in the two configs). Then run the builders.

The two builders are **independent** (audio = speakers/kernel; power = CPU power/fan/Fn-Q), but
run them in this order: **audio → reboot into the audio kernel → power → tweaks.** The power installer
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

# --- 5. Fixes & features: resume hooks (speakers + power cap survive sleep), governor,
#        snapshots, hw video decode, etc.  Run last, after audio + power are in place. ---
./Build_16iax10h_tweaks.sh
./Build_16iax10h_tweaks.sh --verify   # expect: N passed, 0 failed
```

After this, the setup maintains itself:
- **Audio** is a separate kernel package — rebuild it with `Build_16iax10h_audio.sh` when a newer
  kernel lands (and a matching patch exists).
- **Power's `legion-laptop` is a DKMS module**, so it auto-rebuilds whenever any kernel's headers
  install (including future audio-kernel rebuilds). Re-run `--verify` to confirm after a rebuild.
- **Tweaks** are mostly install-once system config; re-run `Build_16iax10h_tweaks.sh --verify` after a
  reboot or major update. The two `systemd-sleep` hooks live in a package dir but aren't
  package-managed, so they survive updates.

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
