# WirePlumber — keep Legion speakers as the default output

Stops laptop audio from being silently routed to an external DisplayPort/HDMI monitor and
keeps the internal **AW88399 speakers** as the default sink — across reboots, monitor
hotplug, and even a full WirePlumber state reset.

## The bug this fixes

The Legion Pro 7 16IAX10H sound card exposes **Speaker** and **Headphones** as two
*mutually exclusive* ALSA/UCM profiles:

| Profile | Profile priority | Has speaker sink? |
| --- | --- | --- |
| `HiFi (HDMI1, HDMI2, HDMI3, Headphones, Mic1)` | **10200** (ships preferred) | ❌ |
| `HiFi (HDMI1, HDMI2, HDMI3, Mic1, Speaker)` | 10100 | ✅ |

If the card is on the **Headphones** profile with no headphones plugged in, the only
*available* outputs are the HDMI/DP ports — so plugging in a monitor (e.g. the XG32UCWMG)
makes that monitor the default sink and the laptop goes silent. EasyEffects follows the
default sink, so the entire EQ chain gets sent to the monitor as well.

Because the Headphones profile has the *higher* priority, a fresh WirePlumber state
auto-selects it and re-triggers the bug.

## What the config does

`51-legion-speaker-default.conf` pins the **Speaker** profile as *preferred* via
`device.profile.priority.rules`. WirePlumber's `find-preferred-profile` hook runs before
the priority-based `find-best-profile`, so the Speaker sink is always present. On that
profile the Speaker node (`priority.session` 1000) also out-ranks every HDMI/DP sink
(664–696), so a monitor can never auto-win the default output.

Together with WirePlumber's stored state
(`~/.local/state/wireplumber/{default-nodes,default-profile}`, where an explicitly chosen
default gets a +30000 priority boost), this makes the speakers-as-default behavior robust.

## Setup

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
cp ~/Arch/dotfiles/wireplumber/51-legion-speaker-default.conf ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

## Verify

```bash
# default sink is the Speaker (not an HDMI/DP monitor):
pactl get-default-sink        # -> ...HiFi__Speaker__sink

# card is on the Speaker profile:
pactl list cards | grep 'Active Profile'   # -> HiFi (HDMI1, HDMI2, HDMI3, Mic1, Speaker)

# the preferred-profile rule was picked up (no config parse errors):
journalctl --user -u wireplumber -b | grep -i "preferred profile"
```

## Want a different default (headphones / monitor)?

Just select it in your audio applet, or `wpctl set-default <id>`. WirePlumber remembers
explicit choices, and this rule only controls the *automatic* fallback.
