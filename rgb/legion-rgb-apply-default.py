#!/usr/bin/env python3
"""Apply the user's default Legion RGB profile (set in the Studio UI) — headless.
Used by the legion-rgb-default systemd service at boot. Reuses Studio's logic."""
import json, os, sys, pwd
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location(
    "studio", os.path.join(os.path.dirname(os.path.realpath(__file__)), "legion-rgb-studio.py"))
studio = importlib.util.module_from_spec(spec); spec.loader.exec_module(studio)

data = studio.load_profiles()
name = data.get("default")
if not name or name not in data.get("profiles", {}):
    print("no default profile set; nothing to apply"); sys.exit(0)
ok, msg = studio.apply_state(data["profiles"][name])
print(f"applied default profile '{name}': ok={ok} {msg}")
sys.exit(0 if ok else 1)
