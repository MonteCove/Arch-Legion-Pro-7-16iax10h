# RGB Fn-key binding — RESUME HERE (paused 2026-06-07)

## Done so far
- Legion RGB Studio (web UI + profiles) built, tested, committed. Install: `./rgb/install-rgb-studio.sh`.
- `rgb/legion-rgb-cycle.sh` written + validated — the "Fn+Space action": cycles saved
  profiles (Windows-like), falls back to brightness off/low/high if <2 profiles. awk
  wrap-around tested (Gaming->Work->Stealth->Gaming).

## The open question (needs hands-on-keyboard)
Which key to bind the cycle to. Legion Fn is often firmware-handled and may emit NO Linux
event. Must capture first:
    sudo pacman -S --needed evtest libinput
    sudo libinput debug-events --show-keycodes   # press Fn+Space (+ other Fn keys), Ctrl-C
- If Fn+Space emits an event -> bind it in ~/.config/hypr (or the 16iax10h-user.conf drop-in)
  to: exec, ~/Arch/rgb/legion-rgb-cycle.sh
- If it emits nothing -> bind Super+Space (or another free combo) instead.

## Decision still needed from user
Cycle action: (a) saved profiles [recommended], (b) brightness only, (c) both on two keys.
This also overlaps the broader Fn-keys task (notes/fn-keys-camera-NEXT-SESSION.md) — capture
ALL Fn keys in the same libinput pass.
