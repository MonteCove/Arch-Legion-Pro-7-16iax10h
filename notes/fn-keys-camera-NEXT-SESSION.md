# Fn keys + camera + kill-switch — research / prep (do this next session)

Initial research done 2026-05-31 while you slept. This is the plan + what I already found, so we can
move fast. **First task when you're back: map which Fn keys actually emit events** (see Step 1).

---

## What I already know (from your live hardware)

### Camera — hardware is fine ✅
- `uvcvideo` loaded, `/dev/video0` + `/dev/video1`, "Integrated Camera" on USB `80:14.0-11`
  (`usb-...Integrated_Camera...`). The camera itself **works** — test with any app, or:
  ```bash
  sudo pacman -S --needed v4l-utils mpv
  mpv av://v4l2:/dev/video0          # should show your webcam feed (Ctrl-C to stop)
  ```

### Camera kill-switch — it's a PHYSICAL SLIDER, not (only) a key 🔑
- This model has a **hardware camera privacy toggle switch** (per the Lenovo user guide). Slide it off →
  the camera is physically disconnected → `/dev/video0` may **disappear** entirely (that's expected and
  *good* — true hardware privacy, nothing to "fix").
- The Fn **camera key** (software toggle) is a separate thing. On your box:
  - `lenovo-wmi-camera.ko` exists on disk but is **NOT loaded**, and
  - its WMI GUID `50C76F1F-D8E4-D895-0A3D-62F4EA400013` is **NOT present in your firmware**.
  - => the in-kernel camera-button driver can't bind on this model. The camera key may do nothing in
    Linux, OR be handled by the EC/physical switch. **Next session: slide the physical switch and watch
    if `/dev/video0` appears/disappears** — if it does, the kill-switch already works (hardware-level).

### Fn keys — handling is partly there, partly blacklisted ⚠️
- Fn keys come from the **ITE 8258** keyboards: `event3` (AT set-2) + `event4` (ITE Device 8258) +
  `event6` ("Wireless Radio Control", has rfkill).
- Loaded + working: `lenovo_wmi_hotkey_utilities`, `lenovo_wmi_events`, `legion_laptop`.
- **Two things our power install blacklisted that may cost some Fn keys:**
  - `lenovo_wmi_gamezone` — blacklisted (it steals the GameZone WMI GUID legion-laptop needs). Some
    Legion-specific Fn keys may route through it. **Trade-off to evaluate.**
  - `ideapad_laptop` — blacklisted (frees VPC2004 + fixes wifi rfkill). Loses ideapad Fn handling.
- **Reality check (from research):** the bare **Fn modifier itself** is handled in the EC/BIOS and is not
  remappable. What we *can* fix is the **Fn+key combos** that either (a) emit an unknown scancode the
  kernel doesn't map, or (b) emit a keysym the Hyprland config doesn't bind to an action.

---

## The plan (in order)

### Step 1 — MAP which Fn keys work vs don't  ← **start here, needs your hands on the keyboard**
Install the tools, then watch what each Fn key emits:
```bash
sudo pacman -S --needed evtest libinput-tools wev
```
- **Terminal A:** `sudo evtest` → pick the **ITE Device(8258)** keyboard (the hotkey one).
- Press **each Fn+key in turn** (F1–F12, brightness, volume, mic-mute, camera, airplane, the Legion
  keys). For each, note one of:
  - **emits a keycode** (e.g. `KEY_BRIGHTNESSUP`) → kernel sees it; if it doesn't *act*, it's a
    Hyprland-binding gap (easy fix).
  - **emits nothing in evtest** → kernel generates no event; also try `acpi_listen` and a second evtest
    on `event3`/`event6`. If truly nothing anywhere → needs a kernel/WMI driver (harder; maybe the
    gamezone or camera driver).
- Also run **`wev`** inside Hyprland for the keys that DO emit — shows the keysym Hyprland receives, so we
  know exactly what to bind.
- **Make a list:** "F5 brightness = works", "Fn+camera = nothing", etc. Paste it to me and we map fixes.

### Step 2 — fix the easy ones (keysym reaches Hyprland but does nothing)
Add binds in `~/.config/hypr/UserConfigs/UserKeybinds.conf` (or the repo `16iax10h-user.conf` drop-in so
it's reproducible). E.g. brightness/volume/mic-mute that emit XF86 keysyms but aren't bound.

### Step 3 — evaluate the gamezone blacklist trade-off
If specific Legion Fn keys emit nothing, test (temporarily, this boot only):
```bash
sudo modprobe lenovo_wmi_gamezone     # try loading it
sudo evtest                            # re-test the dead keys
# if it helps AND legion-laptop still works (check: ./Build_16iax10h_power.sh --verify),
# we reconsider the blacklist. If it breaks legion power control, we revert.
sudo modprobe -r lenovo_wmi_gamezone   # undo
```
This is the one place Fn keys and our power setup might conflict — we'll measure, not guess.

### Step 4 — camera kill-switch
- Confirm the **physical slider** disconnects the camera (watch `/dev/video0` with the switch).
- If you want a **software** camera toggle (Fn-key style) and the hardware key is dead, we can bind a
  Hyprland key to a script that unbinds/rebinds the uvcvideo device — a userspace "soft kill-switch".

### Step 5 — make it reproducible
Whatever we fix (keybinds, any modprobe change), fold into the repo: keybinds → the `16iax10h-user.conf`
drop-in (deployed by the `display` module); any package → `PACKAGES.md`.

---

## Open questions for you
- Which specific Fn keys are dead? (Step 1 gives the list.)
- Does the physical camera slider work? (Watch `/dev/video0`.)
- Is there a BIOS "Hotkey Mode" / "Fn Lock" setting? (Fn+Esc toggles FnLock; BIOS may have a mode toggle.)

## Sources
- [Legion Pro 7 16IAX10H user guide (Lenovo)](https://download.lenovo.com/pccbbs/pubs/legion_pro7_16_10/user_guide/en/index.html)
- [Lenovo Fn & Function Keys (camera/mic FN shortcuts)](https://forums.lenovo.com/t5/Gaming-Laptops/Enable-Disable-Camera-and-Microphone-shortcuts-FN-key/m-p/5088145)
- [Arch BBS — Fn keys not recognized (evtest/acpi_listen method)](https://bbs.archlinux.org/viewtopic.php?id=229572)
- Raw hardware dump captured at `/tmp/legion-fnkeys-research.txt` (this boot).
