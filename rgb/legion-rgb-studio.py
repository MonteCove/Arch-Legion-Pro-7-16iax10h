#!/usr/bin/env python3
"""
legion-rgb-studio — a polished, fully-editable web UI for the Lenovo Legion Pro 7
16IAX10H per-key RGB keyboard. Serves http://127.0.0.1:5566 and drives the audited
`spectrum-ctl` CLI (it does NOT touch HID directly). Profiles are stored as JSON.

Run:   sudo legion-rgb-studio            # sudo so spectrum-ctl can write the keyboard
Then:  open http://127.0.0.1:5566

Pure stdlib (http.server, json, subprocess). No external deps.
"""
import json, os, subprocess, shlex, html, pwd
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SPECTRUM = "/usr/local/bin/spectrum-ctl"
PORT = 5566
HOST = "127.0.0.1"

# profiles live in the invoking (non-root) user's config dir, even under sudo
def _real_home():
    u = os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
    return pwd.getpwnam(u).pw_dir, u
HOME, REAL_USER = _real_home()
CFG_DIR = os.path.join(HOME, ".config", "legion-rgb-studio")
PROFILES = os.path.join(CFG_DIR, "profiles.json")

# ---- validated control surface (must mirror spectrum-ctl) ----
EFFECTS = ["static", "rainbow-wave", "screw-rainbow", "color-change", "color-pulse",
           "color-wave", "smooth", "rain", "ripple", "type", "audio-bounce", "audio-ripple"]
ZONES = ["keyboard", "perimeter", "logo", "all"]
DIRECTIONS = ["up", "down", "left", "right"]
NAMED = ["white", "red", "green", "blue", "cyan", "magenta", "yellow",
         "orange", "purple", "pink", "off"]
KEY_GROUPS = ["wasd", "arrows", "numpad", "fkeys"]

# keycodes valid for per-key writes (names spectrum-ctl resolves) — used to validate
VALID_KEYCODES = set(range(0x0001, 0x0600))  # broad; spectrum-ctl rejects unknowns safely


def run_ctl(args):
    """Run spectrum-ctl with a validated argv list (never shell=True). Returns (ok, output)."""
    try:
        p = subprocess.run([SPECTRUM] + args, capture_output=True, text=True, timeout=15)
        return (p.returncode == 0, (p.stdout + p.stderr).strip())
    except Exception as e:
        return (False, f"error: {e}")


def is_hex(c):
    return isinstance(c, str) and len(c) == 7 and c[0] == "#" and all(
        ch in "0123456789abcdefABCDEF" for ch in c[1:])


def safe_color(c):
    """Accept #RRGGBB, named, or R,G,B -> return a token spectrum-ctl accepts, else None."""
    if c in NAMED:
        return c
    if is_hex(c):
        return c
    if isinstance(c, str) and "," in c:
        parts = c.split(",")
        if len(parts) == 3 and all(p.strip().isdigit() and 0 <= int(p) <= 255 for p in parts):
            return c
    return None


def safe_keycode(k):
    """Accept 0xNNNN int/str or a known key-group name."""
    if k in KEY_GROUPS:
        return k
    try:
        v = int(str(k), 16) if str(k).lower().startswith("0x") else int(k)
        if v in VALID_KEYCODES:
            return f"0x{v:04x}"
    except (ValueError, TypeError):
        pass
    return None


# ---- profile store ----
def load_profiles():
    try:
        with open(PROFILES) as f:
            return json.load(f)
    except (IOError, ValueError):
        return {"profiles": {}, "default": None}


def save_profiles(data):
    os.makedirs(CFG_DIR, exist_ok=True)
    tmp = PROFILES + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, PROFILES)
    # keep ownership with the real user, not root
    try:
        pw = pwd.getpwnam(REAL_USER)
        for p in (CFG_DIR, PROFILES):
            os.chown(p, pw.pw_uid, pw.pw_gid)
    except (KeyError, PermissionError):
        pass


def get_status():
    ok, out = run_ctl(["status"])
    st = {"brightness": None, "profile": None, "logo": None, "raw": out, "ok": ok}
    for line in out.splitlines():
        low = line.lower()
        if "brightness" in low:
            st["brightness"] = _firstint(line)
        elif "profile" in low:
            st["profile"] = _firstint(line)
        elif "logo" in low:
            st["logo"] = "on" in low
    return st


def _firstint(s):
    n = ""
    for ch in s:
        if ch.isdigit():
            n += ch
        elif n:
            break
    return int(n) if n else None


# ---- apply a UI state to the hardware via spectrum-ctl ----
def apply_state(state):
    """state: {mode, keys{code:hex}, effect, speed, dir, zones[], colors[], brightness, logo}"""
    msgs = []
    # brightness first (so effects become visible)
    b = state.get("brightness")
    if isinstance(b, int) and 0 <= b <= 9:
        ok, o = run_ctl(["brightness", str(b)]); msgs.append(o)
    # logo
    lg = state.get("logo")
    if lg in (True, False):
        ok, o = run_ctl(["logo", "on" if lg else "off"]); msgs.append(o)

    mode = state.get("mode")
    if mode == "perkey":
        # group keys by color -> spectrum-ctl keys 0xCODE:#hex ...
        keys = state.get("keys", {})
        args = []
        for code, color in keys.items():
            sc, kc = safe_color(color), safe_keycode(code)
            if sc and kc:
                args.append(f"{kc}:{sc}")
        if args:
            ok, o = run_ctl(["keys"] + args); msgs.append(o)
        else:
            msgs.append("no valid per-key assignments")
    elif mode == "effect":
        eff = state.get("effect", "static")
        if eff not in EFFECTS:
            return False, f"bad effect {eff}"
        zones = [z for z in state.get("zones", ["all"]) if z in ZONES] or ["all"]
        colors = [safe_color(c) for c in state.get("colors", [])]
        colors = [c for c in colors if c]
        args = ["preset", eff] + zones + colors
        sp = state.get("speed")
        if isinstance(sp, int) and 1 <= sp <= 3:
            args += ["--speed", str(sp)]
        d = state.get("dir")
        if d in DIRECTIONS:
            args += ["--dir", d]
        ok, o = run_ctl(args); msgs.append(o)
    elif mode == "multi":
        specs = []
        for z in state.get("multi", []):
            zn, ef, col = z.get("zone"), z.get("effect"), z.get("color")
            if zn in ZONES and ef in EFFECTS:
                sc = safe_color(col) if col else None
                specs.append(f"{zn}:{ef}:{sc}" if sc else f"{zn}:{ef}:")
        if specs:
            ok, o = run_ctl(["multi"] + specs); msgs.append(o)
    elif mode == "quick":
        q = state.get("quick")
        if q in ("rgb", "white", "stealth", "off", "on"):
            ok, o = run_ctl([q]); msgs.append(o)
    return True, " | ".join(m for m in msgs if m)


# ---- HTTP ----
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif self.path == "/api/status":
            self._send(200, get_status())
        elif self.path == "/api/profiles":
            self._send(200, load_profiles())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self._read_json()
        if self.path == "/api/apply":
            ok, msg = apply_state(body)
            self._send(200, {"ok": ok, "msg": msg})
        elif self.path == "/api/profiles":            # save/update a profile
            name = (body.get("name") or "").strip()[:40]
            if not name:
                return self._send(400, {"error": "name required"})
            data = load_profiles()
            data["profiles"][name] = body.get("state", {})
            save_profiles(data)
            self._send(200, {"ok": True, "saved": name})
        elif self.path == "/api/profile/load":
            data = load_profiles()
            st = data["profiles"].get(body.get("name"))
            if st is None:
                return self._send(404, {"error": "no such profile"})
            ok, msg = apply_state(st)
            self._send(200, {"ok": ok, "msg": msg, "state": st})
        elif self.path == "/api/profile/default":
            data = load_profiles()
            nm = body.get("name")
            if nm not in data["profiles"]:
                return self._send(404, {"error": "no such profile"})
            data["default"] = nm
            save_profiles(data)
            self._send(200, {"ok": True, "default": nm})
        elif self.path == "/api/profile/delete":
            data = load_profiles()
            nm = body.get("name")
            data["profiles"].pop(nm, None)
            if data.get("default") == nm:
                data["default"] = None
            save_profiles(data)
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})


# the front-end (single page). Kept in a module-level string; data tables injected as JSON.
KB_KEYS = [
 ["Esc",0x0001,1,4,1,1],["F1",0x0002,6,3,1,1],["F2",0x0003,9,4,1,1],["F3",0x0004,13,3,1,1],
 ["F4",0x0005,16,4,1,1],["F5",0x0006,21,3,1,1],["F6",0x0007,24,4,1,1],["F7",0x0008,28,3,1,1],
 ["F8",0x0009,31,4,1,1],["F9",0x000a,36,3,1,1],["F10",0x000b,39,4,1,1],["F11",0x000c,43,3,1,1],
 ["F12",0x000d,46,4,1,1],["Ins",0x000e,51,3,1,1],["PrtSc",0x000f,54,3,1,1],["Del",0x0010,57,4,1,1],
 ["Home",0x0011,62,3,1,1],["End",0x0012,65,3,1,1],["PgUp",0x0013,68,3,1,1],["PgDn",0x0014,71,3,1,1],
 ["~",0x0016,1,4,2,1],["1",0x0017,5,4,2,1],["2",0x0018,9,4,2,1],["3",0x0019,13,4,2,1],
 ["4",0x001a,17,4,2,1],["5",0x001b,21,4,2,1],["6",0x001c,25,4,2,1],["7",0x001d,29,4,2,1],
 ["8",0x001e,33,4,2,1],["9",0x001f,37,4,2,1],["0",0x0020,41,4,2,1],["-",0x0021,45,4,2,1],
 ["=",0x0022,49,4,2,1],["Bksp",0x0038,53,8,2,1],["Num",0x0026,62,3,2,1],["/",0x0027,65,3,2,1],
 ["*",0x0028,68,3,2,1],["−",0x0029,71,3,2,1],
 ["Tab",0x0040,1,6,3,1],["Q",0x0042,7,4,3,1],["W",0x0043,11,4,3,1],["E",0x0044,15,4,3,1],
 ["R",0x0045,19,4,3,1],["T",0x0046,23,4,3,1],["Y",0x0047,27,4,3,1],["U",0x0048,31,4,3,1],
 ["I",0x0049,35,4,3,1],["O",0x004a,39,4,3,1],["P",0x004b,43,4,3,1],["[",0x004c,47,4,3,1],
 ["]",0x004d,51,4,3,1],["\\",0x004e,55,6,3,1],["7",0x004f,62,3,3,1],["8",0x0050,65,3,3,1],
 ["9",0x0051,68,3,3,1],["+",0x0068,71,3,3,2],
 ["Caps",0x0055,1,7,4,1],["A",0x006d,8,4,4,1],["S",0x006e,12,4,4,1],["D",0x0058,16,4,4,1],
 ["F",0x0059,20,4,4,1],["G",0x005a,24,4,4,1],["H",0x0071,28,4,4,1],["J",0x0072,32,4,4,1],
 ["K",0x005b,36,4,4,1],["L",0x005c,40,4,4,1],[";",0x005d,44,4,4,1],["'",0x005f,48,4,4,1],
 ["Enter",0x0077,52,9,4,1],["4",0x0079,62,3,4,1],["5",0x007b,65,3,4,1],["6",0x007c,68,3,4,1],
 ["Shift",0x006a,1,9,5,1],["Z",0x0082,10,4,5,1],["X",0x0083,14,4,5,1],["C",0x006f,18,4,5,1],
 ["V",0x0070,22,4,5,1],["B",0x0087,26,4,5,1],["N",0x0088,30,4,5,1],["M",0x0073,34,4,5,1],
 [",",0x0074,38,4,5,1],[".",0x0075,42,4,5,1],["/",0x0076,46,4,5,1],["Shift",0x008d,50,11,5,1],
 ["1",0x008e,62,3,5,1],["2",0x0090,65,3,5,1],["3",0x0092,68,3,5,1],["Ent",0x00a7,71,3,5,2],
 ["Ctrl",0x007f,1,6,6,1],["Fn",0x0080,7,4,6,1],["❖",0x0096,11,5,6,1],["Alt",0x0097,16,5,6,1],
 ["Space",0x0098,21,22,6,1],["Alt",0x009a,43,5,6,1],["⬢",0x009b,48,5,6,1],["↑",0x009d,55,3,6,1],
 ["0",0x00a3,62,6,6,1],[".",0x00a5,68,3,6,1],
 ["←",0x009c,52,3,7,1],["↓",0x009f,55,3,7,1],["→",0x00a1,58,3,7,1],
]
PERIM_REAR = [0x03e9,0x03ea,0x03eb,0x03ec,0x03ed,0x03ee,0x03ef,0x03f0,0x03f1,0x03f2,
              0x03f3,0x03f4,0x03f5,0x03f6,0x03f7,0x03f8,0x03f9,0x03fa]
PERIM_FRONT = [0x01f5,0x01f6,0x01f7,0x01f8,0x01f9,0x01fa,0x01fb,0x01fc,0x01fd,0x01fe]

DATA = json.dumps({
    "kb": KB_KEYS, "perimRear": PERIM_REAR, "perimFront": PERIM_FRONT,
    "effects": EFFECTS, "zones": ["keyboard", "perimeter", "logo"], "dirs": DIRECTIONS,
    "named": NAMED, "groups": KEY_GROUPS,
})

PAGE = r"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Legion RGB Studio</title>
<style>
:root{--bg:#0b0d12;--panel:#141823;--panel2:#1c2230;--edge:#2a3242;--txt:#e6e9f0;--mut:#8a93a6;
--acc:#7c5cff;--acc2:#00d4ff;--ok:#36d399;--warn:#fbbf24;--rad:12px}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 600px at 70% -10%,#1a1f30,var(--bg));
color:var(--txt);font:14px/1.5 'Inter',system-ui,sans-serif}
header{display:flex;align-items:center;gap:14px;padding:16px 22px;border-bottom:1px solid var(--edge);
background:linear-gradient(90deg,#141823,#10131c)}
header h1{font-size:18px;margin:0;font-weight:700;letter-spacing:.3px}
header .logo{width:30px;height:30px;border-radius:8px;background:conic-gradient(from 0deg,#f00,#ff0,#0f0,#0ff,#00f,#f0f,#f00);box-shadow:0 0 16px #7c5cff80}
header .status{margin-left:auto;display:flex;gap:18px;color:var(--mut);font-size:13px}
header .status b{color:var(--txt)}
.wrap{max-width:1180px;margin:0 auto;padding:22px}
.card{background:var(--panel);border:1px solid var(--edge);border-radius:var(--rad);padding:18px;margin-bottom:18px;box-shadow:0 8px 24px #0006}
.card h2{margin:0 0 14px;font-size:15px;font-weight:600;display:flex;align-items:center;gap:8px}
.card h2 .dot{width:8px;height:8px;border-radius:50%;background:var(--acc)}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.row+.row{margin-top:12px}
label.lbl{color:var(--mut);font-size:12px;min-width:74px}
button,select,input[type=text],input[type=number]{background:var(--panel2);color:var(--txt);
border:1px solid var(--edge);border-radius:8px;padding:8px 12px;font:inherit;cursor:pointer;transition:.15s}
button:hover{border-color:var(--acc);background:#232b3d}
button.primary{background:linear-gradient(90deg,var(--acc),#6344e6);border:none;font-weight:600}
button.primary:hover{filter:brightness(1.1)}
button.ghost{background:transparent}
button.sm{padding:5px 9px;font-size:12px}
input[type=color]{width:46px;height:36px;padding:2px;border-radius:8px;border:1px solid var(--edge);background:var(--panel2);cursor:pointer}
input[type=range]{accent-color:var(--acc);cursor:pointer}
.tabs{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
.tab{padding:9px 16px;border-radius:10px;background:var(--panel);border:1px solid var(--edge);color:var(--mut);font-weight:600}
.tab.active{color:#fff;background:linear-gradient(90deg,var(--acc),#6344e6);border-color:transparent}
.hide{display:none}
/* keyboard */
#kbWrap{overflow-x:auto;padding:14px;background:var(--panel2);border-radius:12px;border:1px solid var(--edge)}
#kb{display:grid;grid-template-columns:repeat(74,11.5px);grid-auto-rows:46px;gap:4px;min-width:880px}
.key{border-radius:6px;border:1px solid #00000060;display:flex;align-items:flex-end;justify-content:center;
font-size:9px;color:#0008;font-weight:700;user-select:none;cursor:pointer;overflow:hidden;
padding-bottom:2px;background:#2a3242;transition:transform .05s,box-shadow .1s;text-shadow:0 1px 1px #fff3}
.key:hover{transform:translateY(-1px);box-shadow:0 0 0 2px var(--acc2)}
.key.sel{box-shadow:0 0 0 2px #fff,0 0 12px var(--acc2)}
.swatches{display:flex;gap:6px;flex-wrap:wrap}
.sw{width:26px;height:26px;border-radius:6px;border:2px solid #fff2;cursor:pointer}
.sw:hover{border-color:#fff}
.perim{display:flex;gap:3px;flex-wrap:wrap;margin-top:8px}
.pled{width:16px;height:16px;border-radius:50%;background:#2a3242;border:1px solid #0006;cursor:pointer}
.pill{padding:4px 10px;border-radius:999px;background:var(--panel2);border:1px solid var(--edge);font-size:12px;color:var(--mut)}
.profiles{display:flex;flex-direction:column;gap:8px}
.prof{display:flex;align-items:center;gap:10px;padding:10px 12px;background:var(--panel2);border:1px solid var(--edge);border-radius:10px}
.prof .nm{font-weight:600}.prof .def{color:var(--ok);font-size:11px;border:1px solid var(--ok);border-radius:999px;padding:1px 8px}
.prof .sp{margin-left:auto;display:flex;gap:6px}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#1c2230;border:1px solid var(--acc);
padding:11px 18px;border-radius:10px;box-shadow:0 8px 30px #000a;opacity:0;transition:.3s;pointer-events:none;max-width:80vw}
.toast.show{opacity:1}
.muted{color:var(--mut);font-size:12px}
.zonechip{padding:7px 13px;border-radius:9px;border:1px solid var(--edge);background:var(--panel2);color:var(--mut);font-weight:600}
.zonechip.on{color:#fff;background:#2a2050;border-color:var(--acc)}
</style></head><body>
<header>
 <div class="logo"></div>
 <h1>Legion RGB Studio</h1>
 <div class="status">
  <span>Brightness <b id="stB">–</b></span>
  <span>Profile <b id="stP">–</b></span>
  <span>Logo <b id="stL">–</b></span>
 </div>
</header>
<div class="wrap">
 <div class="tabs">
  <div class="tab active" data-tab="perkey">⌨ Per-Key</div>
  <div class="tab" data-tab="effects">✨ Effects</div>
  <div class="tab" data-tab="multi">🎚 Multi-Zone</div>
  <div class="tab" data-tab="profiles">💾 Profiles</div>
  <div class="tab" data-tab="quick">⚡ Quick</div>
 </div>

 <!-- shared color + brightness/logo bar -->
 <div class="card">
  <div class="row">
   <label class="lbl">Color</label>
   <input type="color" id="color" value="#7c5cff">
   <input type="text" id="hex" value="#7c5cff" style="width:96px">
   <div class="swatches" id="swatches"></div>
  </div>
  <div class="row">
   <label class="lbl">Brightness</label>
   <input type="range" id="bright" min="0" max="9" value="5" style="width:200px">
   <span class="pill" id="brightV">5</span>
   <label class="lbl" style="margin-left:18px">Logo</label>
   <button id="logoBtn" class="sm">toggle</button>
   <span class="pill" id="logoV">?</span>
  </div>
 </div>

 <!-- PER-KEY -->
 <div class="card tabpane" id="pane-perkey">
  <h2><span class="dot"></span>Per-Key Painter</h2>
  <div class="row" style="margin-bottom:12px">
   <button class="sm" onclick="selGroup('wasd')">WASD</button>
   <button class="sm" onclick="selGroup('arrows')">Arrows</button>
   <button class="sm" onclick="selGroup('numpad')">Numpad</button>
   <button class="sm" onclick="selGroup('fkeys')">F-keys</button>
   <button class="sm" onclick="selAll()">Select All</button>
   <button class="sm" onclick="clearSel()">Clear Selection</button>
   <button class="sm" onclick="paintSel()">🖌 Paint Selected</button>
   <button class="sm ghost" onclick="eraseSel()">Erase Selected</button>
   <span class="muted">Click a key to paint it the current color · drag to paint many · click-select with Shift then “Paint Selected”.</span>
  </div>
  <div id="kbWrap"><div id="kb"></div></div>
  <div class="row" style="margin-top:12px">
   <button class="primary" onclick="applyPerKey()">Apply Per-Key to Keyboard</button>
   <button class="ghost" onclick="fillAll()">Fill All Keys (current color)</button>
   <button class="ghost" onclick="resetKeys()">Reset (black)</button>
  </div>
 </div>

 <!-- EFFECTS -->
 <div class="card tabpane hide" id="pane-effects">
  <h2><span class="dot"></span>Effect</h2>
  <div class="row"><label class="lbl">Effect</label><select id="fxEffect"></select>
   <label class="lbl" style="margin-left:14px">Speed</label><input type="range" id="fxSpeed" min="1" max="3" value="2"><span class="pill" id="fxSpeedV">2</span>
   <label class="lbl" style="margin-left:14px">Direction</label><select id="fxDir"><option value="">—</option></select>
  </div>
  <div class="row"><label class="lbl">Zones</label><span id="fxZones"></span></div>
  <div class="row"><label class="lbl">Colors</label>
   <input type="color" id="fxC1" value="#7c5cff"><input type="color" id="fxC2" value="#00d4ff">
   <span class="muted">(some effects use 1–2 colors; rainbow ignores them)</span>
  </div>
  <div class="row"><button class="primary" onclick="applyEffect()">Apply Effect</button></div>
 </div>

 <!-- MULTI -->
 <div class="card tabpane hide" id="pane-multi">
  <h2><span class="dot"></span>Multi-Zone</h2>
  <div id="mzRows"></div>
  <div class="row"><button class="primary" onclick="applyMulti()">Apply All Zones</button></div>
 </div>

 <!-- PROFILES -->
 <div class="card tabpane hide" id="pane-profiles">
  <h2><span class="dot"></span>Profiles</h2>
  <div class="row" style="margin-bottom:12px">
   <input type="text" id="profName" placeholder="Profile name (e.g. Gaming)" style="width:240px">
   <button class="primary" onclick="saveProfile()">💾 Save Current State</button>
   <span class="muted">Saves whatever the active tab last applied (per-key / effect / multi).</span>
  </div>
  <div class="profiles" id="profList"></div>
 </div>

 <!-- QUICK -->
 <div class="card tabpane hide" id="pane-quick">
  <h2><span class="dot"></span>Quick Presets</h2>
  <div class="row">
   <button onclick="quick('rgb')">🌈 Rainbow All</button>
   <button onclick="quick('white')">⬜ White Keys</button>
   <button onclick="quick('on')">💡 All On</button>
   <button onclick="quick('off')">◻ All Off</button>
   <button onclick="quick('stealth')">🥷 Stealth</button>
  </div>
 </div>
</div>
<div class="toast" id="toast"></div>
<script>
const D = __DATA__;
let lastState = null;          // last-applied state (what Save Profile captures)
let curColor = "#7c5cff";
const keyColor = {};           // code(int) -> hex
let selected = new Set();
let painting = false;

function $(id){return document.getElementById(id)}
function toast(m,good){const t=$('toast');t.textContent=m;t.style.borderColor=good===false?'#f87171':'var(--acc)';t.classList.add('show');clearTimeout(t._t);t._t=setTimeout(()=>t.classList.remove('show'),2600)}
async function api(path,method,body){const r=await fetch(path,{method:method||'GET',headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});return r.json()}

// ---- tabs ----
document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{
 document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));t.classList.add('active');
 document.querySelectorAll('.tabpane').forEach(p=>p.classList.add('hide'));
 $('pane-'+t.dataset.tab).classList.remove('hide');
});

// ---- color ----
$('color').oninput=e=>{curColor=e.target.value;$('hex').value=curColor};
$('hex').onchange=e=>{let v=e.target.value.trim();if(/^#?[0-9a-fA-F]{6}$/.test(v)){if(v[0]!=='#')v='#'+v;curColor=v;$('color').value=v;$('hex').value=v}};
const swatchCols=['#ff0000','#ff7700','#ffdd00','#00ff66','#00d4ff','#0066ff','#7c5cff','#ff00cc','#ffffff','#000000'];
swatchCols.forEach(c=>{const s=document.createElement('div');s.className='sw';s.style.background=c;s.title=c;s.onclick=()=>{curColor=c;$('color').value=c;$('hex').value=c};$('swatches').appendChild(s)});

// ---- brightness / logo ----
$('bright').oninput=e=>$('brightV').textContent=e.target.value;
$('bright').onchange=e=>api('/api/apply','POST',{brightness:+e.target.value}).then(()=>refresh());
$('logoBtn').onclick=async()=>{const on=$('logoV').textContent!=='on';await api('/api/apply','POST',{logo:on});refresh()};

// ---- build keyboard ----
const kb=$('kb');
D.kb.forEach(([label,code,col,span,row,rspan])=>{
 const d=document.createElement('div');d.className='key';d.dataset.code=code;
 d.style.gridColumn=`${col} / span ${span}`;d.style.gridRow=`${row} / span ${rspan}`;
 d.textContent=label;
 d.onmousedown=ev=>{ev.preventDefault();painting=true;if(ev.shiftKey){toggleSel(code,d)}else{paintKey(code,d)}};
 d.onmouseenter=()=>{if(painting&&!event.shiftKey)paintKey(code,d)};
 kb.appendChild(d);
});
document.addEventListener('mouseup',()=>painting=false);
function paintKey(code,d){keyColor[code]=curColor;d.style.background=curColor;d.style.color=contrast(curColor)}
function toggleSel(code,d){if(selected.has(code)){selected.delete(code);d.classList.remove('sel')}else{selected.add(code);d.classList.add('sel')}}
function contrast(hex){const n=parseInt(hex.slice(1),16);const l=(0.299*(n>>16&255)+0.587*(n>>8&255)+0.114*(n&255));return l>140?'#0008':'#fff8'}
function keyEl(code){return kb.querySelector(`[data-code="${code}"]`)}
function selGroup(g){const map={wasd:['w','a','s','d'],arrows:['up','down','left','right'],
 fkeys:['f1','f2','f3','f4','f5','f6','f7','f8','f9','f10','f11','f12']};
 // resolve by label for simplicity; numpad via codes
 clearSel();
 if(g==='numpad'){[0x0026,0x0027,0x0028,0x0029,0x004f,0x0050,0x0051,0x0068,0x0079,0x007b,0x007c,0x008e,0x0090,0x0092,0x00a3,0x00a5,0x00a7].forEach(c=>{const e=keyEl(c);if(e){selected.add(c);e.classList.add('sel')}});return}
 const want=map[g];D.kb.forEach(([lbl,code])=>{if(want.includes(lbl.toLowerCase())){selected.add(code);keyEl(code).classList.add('sel')}});
}
function selAll(){D.kb.forEach(([l,c])=>{selected.add(c);keyEl(c).classList.add('sel')})}
function clearSel(){selected.forEach(c=>keyEl(c)&&keyEl(c).classList.remove('sel'));selected.clear()}
function paintSel(){selected.forEach(c=>{const e=keyEl(c);keyColor[c]=curColor;e.style.background=curColor;e.style.color=contrast(curColor)})}
function eraseSel(){selected.forEach(c=>{const e=keyEl(c);delete keyColor[c];e.style.background='#2a3242';e.style.color='#0008'})}
function fillAll(){D.kb.forEach(([l,c])=>{const e=keyEl(c);keyColor[c]=curColor;e.style.background=curColor;e.style.color=contrast(curColor)})}
function resetKeys(){D.kb.forEach(([l,c])=>{const e=keyEl(c);delete keyColor[c];e.style.background='#2a3242';e.style.color='#0008'})}

async function applyPerKey(){
 const keys={};Object.entries(keyColor).forEach(([c,h])=>{keys['0x'+(+c).toString(16).padStart(4,'0')]=h});
 if(!Object.keys(keys).length)return toast('Paint some keys first',false);
 const st={mode:'perkey',keys,brightness:+$('bright').value};
 const r=await api('/api/apply','POST',st);lastState=st;toast(r.ok?'Per-key applied ✓':'Failed: '+r.msg,r.ok);refresh();
}

// ---- effects ----
D.effects.forEach(e=>{const o=document.createElement('option');o.value=e;o.textContent=e;$('fxEffect').appendChild(o)});
D.dirs.forEach(d=>{const o=document.createElement('option');o.value=d;o.textContent=d;$('fxDir').appendChild(o)});
$('fxSpeed').oninput=e=>$('fxSpeedV').textContent=e.target.value;
const fxZ={};D.zones.forEach(z=>{const b=document.createElement('span');b.className='zonechip'+(z==='keyboard'?' on':'');b.textContent=z;fxZ[z]=z==='keyboard';
 b.onclick=()=>{fxZ[z]=!fxZ[z];b.classList.toggle('on')};$('fxZones').appendChild(b)});
async function applyEffect(){
 const zones=Object.keys(fxZ).filter(z=>fxZ[z]);if(!zones.length)return toast('Pick a zone',false);
 const st={mode:'effect',effect:$('fxEffect').value,speed:+$('fxSpeed').value,
  dir:$('fxDir').value||undefined,zones,colors:[$('fxC1').value,$('fxC2').value],brightness:+$('bright').value};
 const r=await api('/api/apply','POST',st);lastState=st;toast(r.ok?'Effect applied ✓':'Failed: '+r.msg,r.ok);refresh();
}

// ---- multi ----
const mz=$('mzRows');
D.zones.forEach(z=>{
 const row=document.createElement('div');row.className='row';
 row.innerHTML=`<label class="lbl" style="text-transform:capitalize">${z}</label>
  <select data-z="${z}" class="mzEff"><option value="">— off —</option>${D.effects.map(e=>`<option>${e}</option>`).join('')}</select>
  <input type="color" class="mzCol" data-z="${z}" value="#7c5cff">`;
 mz.appendChild(row);
});
async function applyMulti(){
 const specs=[];document.querySelectorAll('.mzEff').forEach(s=>{const z=s.dataset.z;if(s.value){
  const col=document.querySelector(`.mzCol[data-z="${z}"]`).value;specs.push({zone:z,effect:s.value,color:col})}});
 if(!specs.length)return toast('Set at least one zone',false);
 const st={mode:'multi',multi:specs,brightness:+$('bright').value};
 const r=await api('/api/apply','POST',st);lastState=st;toast(r.ok?'Multi-zone applied ✓':'Failed: '+r.msg,r.ok);refresh();
}

// ---- quick ----
async function quick(q){const st={mode:'quick',quick:q};const r=await api('/api/apply','POST',st);lastState=st;toast(r.ok?q+' ✓':'Failed',r.ok);refresh()}

// ---- profiles ----
async function saveProfile(){
 const name=$('profName').value.trim();if(!name)return toast('Enter a name',false);
 if(!lastState)return toast('Apply a lighting setup first, then save',false);
 await api('/api/profiles','POST',{name,state:lastState});$('profName').value='';toast('Saved “'+name+'” ✓');loadProfiles();
}
async function loadProfiles(){
 const d=await api('/api/profiles');const list=$('profList');list.innerHTML='';
 const names=Object.keys(d.profiles||{});
 if(!names.length){list.innerHTML='<span class="muted">No saved profiles yet. Apply a look, name it, and Save.</span>';return}
 names.forEach(n=>{const row=document.createElement('div');row.className='prof';
  row.innerHTML=`<span class="nm">${n}</span>${d.default===n?'<span class="def">default</span>':''}
   <span class="sp">
    <button class="sm primary" data-a="load">Load</button>
    <button class="sm" data-a="def">Set Default</button>
    <button class="sm ghost" data-a="del">Delete</button>
   </span>`;
  row.querySelector('[data-a=load]').onclick=async()=>{const r=await api('/api/profile/load','POST',{name:n});toast(r.ok?'Loaded “'+n+'” ✓':'Failed',r.ok);refresh()};
  row.querySelector('[data-a=def]').onclick=async()=>{await api('/api/profile/default','POST',{name:n});toast('“'+n+'” is now the boot default');loadProfiles()};
  row.querySelector('[data-a=del]').onclick=async()=>{if(confirm('Delete “'+n+'”?')){await api('/api/profile/delete','POST',{name:n});loadProfiles()}};
  list.appendChild(row)});
}

// ---- status ----
async function refresh(){const s=await api('/api/status');
 $('stB').textContent=s.brightness??'–';$('stP').textContent=s.profile??'–';$('stL').textContent=s.logo?'on':'off';
 $('logoV').textContent=s.logo?'on':'off';
 if(typeof s.brightness==='number'){$('bright').value=s.brightness;$('brightV').textContent=s.brightness}
}
refresh();loadProfiles();
</script></body></html>
""".replace("__DATA__", DATA)


def main():
    os.makedirs(CFG_DIR, exist_ok=True)
    if not os.path.exists(SPECTRUM):
        print(f"ERROR: {SPECTRUM} not found. Install legion-spectrum-control first.")
        raise SystemExit(1)
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Legion RGB Studio → http://{HOST}:{PORT}  (profiles: {PROFILES})")
    print("Ctrl-C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
