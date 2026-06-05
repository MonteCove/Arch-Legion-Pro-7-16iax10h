# Intel NPU (AI Boost) + OpenVINO — setup & verification

**Status: ✅ WORKING** — verified 2026-06-05 on kernel 7.0.10-…-16iax10h-audio.
OpenVINO sees `Intel(R) AI Boost`; a tiny MLP compiled to the NPU ran **~2,180 infer/s**.

The NPU is the Arrow Lake-HX neural accelerator (PCI `8086:AD1D`, `/dev/accel/accel0`,
kernel driver `intel_vpu`). The kernel side + firmware (`vpu_40xx_v1.bin`) ship with
`linux-firmware` and were already loaded; only the **userspace** needed installing.

---

## Packages (AUR via yay; only `level-zero-loader` is official)

```bash
yay -S --needed \
  openvino \
  openvino-intel-npu-plugin \
  python-openvino \
  python-openvino-telemetry \
  nputop-git
# pulls in as deps: intel-npu-driver, intel-npu-compiler, level-zero-loader (extra)
```

Installed versions (this machine):
| pkg | ver | source |
|---|---|---|
| level-zero-loader | 1.28.2 | extra |
| intel-npu-driver | 1.33.0 | AUR |
| intel-npu-compiler | 2026.20rc1 | AUR |
| openvino | 2026.2.0 | AUR |
| openvino-intel-npu-plugin | 2026.2.0 | AUR (NPU plugin → plugins.xml) |
| python-openvino | 2026.2.0 | AUR (built for **Python 3.14**, matches system — no venv needed) |
| python-openvino-telemetry | 2025.2.0 | AUR (dep of python-openvino) |
| nputop-git | r12 | AUR (live NPU usage monitor) |

> yay prompt tips (learned the hard way): at **"Packages to cleanBuild?"** answer **N**
> (None) — answering `A` wipes the already-built packages and forces a full multi-minute
> recompile. Keep your sudo password ready: the OpenVINO/NPU-compiler build is long and a
> stale sudo timestamp makes the final install step fail with "sudo: timed out reading password"
> (the packages are still built in `~/.cache/yay/*/` — just re-run to install them).

---

## Required: add yourself to the `render` group

The NPU driver's udev rule sets `/dev/accel/accel0` to `root:render 0660`, so NPU access
needs the `render` group:

```bash
sudo usermod -aG render "$USER"
# then LOG OUT AND BACK IN (so the whole desktop session gets it; newgrp only fixes one shell)
```
Without this, OpenVINO lists only `['CPU']` and the NPU is invisible.

---

## Verify

```bash
python -c "import openvino as ov; print(ov.Core().available_devices)"
# want: ['CPU', 'NPU']   (GPU appears too if openvino-intel-gpu-plugin is installed)

python ~/Arch/notes/npu-test.py     # compiles a model to the NPU + times 1000 inferences
nputop                               # live NPU utilization (watch it spike during the test)
```

## API note (OpenVINO 2026)
The `openvino.runtime` namespace was **removed** in 2026. Use `import openvino as ov` and
`import openvino.opset16 as ops` (not `openvino.runtime.opset13`). See `npu-test.py`.

## Harmless noise
- `hwloc … invalid information … intersection without inclusion` — cosmetic; Arrow Lake's
  hybrid P/E cluster topology confuses hwloc. OpenVINO ignores it and runs fine.
- Output prints twice in the test — OpenVINO's CPU plugin forks a worker process; benign.

## What it's for
OpenVINO inference offload to the NPU: webcam background-blur, local vision/LLM/Whisper
models, etc. — low-power AI that doesn't wake the dGPU. The runtime is ready; bring any
ONNX/OpenVINO-IR model and target device `"NPU"`.
