# 16IAX10H custom shell aliases.
# Source from ~/.zshrc:   source ~/Arch/dotfiles/zsh/aliases.zsh
# (or just copy these lines into ~/.zshrc)

# --- OLED screen ---
# Turn the OLED panel off (wakes on any key/mouse). 'soff' = quick screen-off.
alias soff='hyprctl dispatch dpms off'
alias son='hyprctl dispatch dpms on'

# --- Battery charge cap (legion conservation_mode: 1=cap ~80%, 0=full 100%) ---
# 'charge100' lifts the cap now (resets to capped on reboot via legion-conservation.service).
# 'chargecap' re-applies the ~80% protective cap. 'chargestatus' shows current state + %.
alias charge100='echo 0 | sudo tee /sys/bus/platform/devices/VPC2004:00/conservation_mode >/dev/null && echo "Charging to 100% (cap OFF until reboot)"'
alias chargecap='echo 1 | sudo tee /sys/bus/platform/devices/VPC2004:00/conservation_mode >/dev/null && echo "Battery cap ON (~80%)"'
alias chargestatus='echo "conservation=$(cat /sys/bus/platform/devices/VPC2004:00/conservation_mode) (1=cap ~80%, 0=full) | battery: $(cat /sys/class/power_supply/BAT0/status) $(cat /sys/class/power_supply/BAT0/capacity)%"'
