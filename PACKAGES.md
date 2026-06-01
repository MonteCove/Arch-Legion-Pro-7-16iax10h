# Packages — Lenovo Legion Pro 7 16IAX10H setup

Every package the scripts in this repo install, what it's for, and which script installs it.
**You don't normally install these by hand** — the `Build_16iax10h_*.sh` scripts run
`pacman -S --needed` for everything below. This file is the reference/explanation.

- **All packages are in the official Arch repos** (`core`/`extra`) — **no AUR helper needed.**
- Everything is installed with `--needed`, so re-running a script never reinstalls what you already have.
- The hardware-base assumption (Hyprland desktop, GPU driver, etc.) is **JaKooLit Arch-Hyprland** — see the
  [Prerequisites](README.md#prerequisites--do-this-first-before-any-script) section of the README.

---

## Quick install (everything at once)

If you just want the package set without running the feature scripts, this single command installs all of
them (the scripts still do the *configuration* — packages alone aren't the whole setup):

```bash
sudo pacman -S --needed \
  base-devel devtools pacman-contrib git bc cpio perl tar xz zstd pahole \
  dkms lm_sensors stress-ng \
  nvidia-open-dkms \
  snapper snap-pac grub-btrfs inotify-tools \
  hypridle hyprlock hyprsunset brightnessctl \
  intel-media-driver libva-utils vulkan-intel \
  nvidia-prime mesa-utils \
  bolt fwupd nftables zram-generator
```

Plus, per kernel you want covered, the matching headers: `linux-headers` (stock), `linux-zen-headers`
(zen). The audio build installs its own headers.

---

## By script

### `Build_16iax10h_audio.sh` — the speaker-patched kernel

Build toolchain to compile a custom kernel package from the Arch `linux` PKGBUILD:

| Package | Why |
|---|---|
| `base-devel` | core build group (gcc, make, fakeroot, etc.) |
| `devtools` | Arch packaging tools (`makepkg`/`pkgctl` helpers) |
| `pacman-contrib` | `pactree`/`paccache` + checksum helpers used by the build |
| `git` | clone/fetch the kernel + patch sources |
| `bc` | kernel build math (config/version arithmetic) |
| `cpio` | initramfs/image packing during the kernel build |
| `perl` | kernel build scripts |
| `tar` `xz` `zstd` | source extraction + compressed image creation |
| `pahole` | BTF debug info generation (`CONFIG_DEBUG_INFO_BTF`) |
| `nvidia-open-dkms` | NVIDIA **open** kernel module (required for Blackwell RTX 50-series); rebuilt by DKMS for the audio kernel |

The script also produces `linux-16iax10h-audio` + `linux-16iax10h-audio-headers` (the kernel itself, not a
dependency you install).

### `Build_16iax10h_power.sh` — legion module + RAPL governor + battery conservation

| Package | Why |
|---|---|
| `base-devel` | compile the `legion-laptop` kernel module |
| `git` | clone the legion driver source |
| `dkms` | register/rebuild `legion-laptop` for every kernel automatically |
| `lm_sensors` | `sensors` — CPU package temp for the governor's thermal guard |
| `stress-ng` | load generator for `legion-powercap --sweep` (characterizing the power ceiling) |

Needs the running kernel's **headers** present (DKMS builds against them).

### `Build_16iax10h_tweaks.sh` — fixes & features (per module)

| Module | Packages | Why |
|---|---|---|
| **snapshots** | `snapper` `snap-pac` `grub-btrfs` `inotify-tools` | Btrfs snapshots, auto-snapshot per pacman txn, bootable snapshot entries in GRUB, and the watcher daemon |
| **zram** | `zram-generator` | sizes the compressed-RAM swap device |
| **hibernate** | *(none)* | uses `btrfs-progs` (already present) for the swapfile; writes config only |
| **video-accel** | `intel-media-driver` `libva-utils` `vulkan-intel` | iGPU hardware video decode (iHD VA-API) + `vainfo` + Intel Vulkan |
| **gpu-offload** | `nvidia-prime` `mesa-utils` | `prime-run <app>` to run a program on the dGPU + `glxinfo` to verify |
| **thunderbolt** | `bolt` | `boltd`/`boltctl` to authorize Thunderbolt 4 devices |
| **firmware** | `fwupd` | firmware updates via LVFS + the refresh timer |
| **firewall** | `nftables` | default-deny-inbound host firewall |
| **display** | `hypridle` `hyprlock` `hyprsunset` `brightnessctl` | OLED idle (dim→off→lock→sleep), screen lock, warm-light, backlight dimming |
| **battery-guard** | *(none)* | a shell script + user service; uses `notify-send` (libnotify, present via the desktop) |
| **cpu-governor / btrfs-scrub / suspend-deep / nvidia-powerd / battery-info / resume-* / spd5118** | *(none)* | config/service only — no new packages |

---

## Other packages this setup relies on (not installed by the scripts)

These come from the base Arch install or JaKooLit, but the setup depends on them:

| Package | Role | Where it comes from |
|---|---|---|
| `linux` / `linux-zen` (+ `*-headers`) | stock/zen kernels DKMS also builds for | base install |
| `intel-ucode` | Intel CPU microcode | base install (`microcode` mkinitcpio hook) |
| `nvidia-utils` | NVIDIA userspace + `nvidia-powerd` + the shipped `nvidia-sleep.conf` | pulled in by `nvidia-open-dkms` |
| `mesa` `vulkan-icd-loader` | iGPU OpenGL/Vulkan | JaKooLit/base |
| `pipewire` `wireplumber` | audio server (the AW88399 amps feed PipeWire) | JaKooLit/base |
| `sof-firmware` | Intel SOF DSP firmware (required for the SOF audio path) | base |
| `grub` | bootloader the scripts edit (`resume=`, `mem_sleep_default`, snapshots) | base install |
| `hyprland` `sddm` `waybar` `swaync` | desktop, login, bar, notifications | JaKooLit |
| `cpupower` | governor service the **cpu-governor** module configures | JaKooLit/base |

---

## One-off diagnostic packages (installed manually during setup, optional)

Used while figuring things out; not required for the finished setup:

| Package | Why it was used |
|---|---|
| `acpica` | `iasl` — decompile the DSDT to verify the battery `SBMC`/`GBMD` conservation methods |
| `acpi_call-dkms` | one-time live test that the conservation EC call worked (before baking it into the driver) |
| `wireless-regdb` | WiFi regulatory database (clears the `regulatory.db failed` boot message; lets the card use full per-country channel/power) |

---

## Notes

- **No AUR required** — every package above is in the official repos.
- **Headers matter for DKMS:** each kernel you boot needs its `*-headers` package, or `legion-laptop` /
  `nvidia` won't build for it. The audio build ships its own; for stock/zen run
  `sudo pacman -S --needed linux-headers linux-zen-headers`.
- To see exactly what a script installs without running it, read its `pac_install ...` lines (tweaks) or
  the `pkgs=`/`pacman -S` lines (audio/power).
