#!/usr/bin/env python3
# NPU offload smoke-test for the Legion Pro 7 16IAX10H (Intel AI Boost NPU).
# Compiles a tiny MLP to the NPU and times inferences -- proves real offload,
# not just device detection. OpenVINO 2026 API (openvino.opset16; .runtime is gone).
#
# Run:  python ~/Arch/notes/npu-test.py
# Watch the NPU light up in another terminal:  nputop
import os, time, numpy as np
os.environ.setdefault("OPENVINO_LOG_LEVEL", "0")
import openvino as ov
import openvino.opset16 as ops

core = ov.Core()
print("OpenVINO:", ov.__version__)
print("Devices :", core.available_devices)
if "NPU" not in core.available_devices:
    raise SystemExit("NPU not visible -- ensure you're in the 'render' group (re-login) and /dev/accel0 is RW.")
print("NPU     :", core.get_property("NPU", "FULL_DEVICE_NAME"))

# tiny model: y = relu(x @ W + b)
N_IN = 1024
x = ops.parameter([1, N_IN], np.float32, name="x")
W = ops.constant(np.random.randn(N_IN, N_IN).astype(np.float32))
b = ops.constant(np.random.randn(N_IN).astype(np.float32))
y = ops.relu(ops.add(ops.matmul(x, W, False, False), b))
model = ov.Model([y], [x], "tiny_mlp")

print("Compiling to NPU ...")
t0 = time.time(); cm = core.compile_model(model, "NPU")
print(f"  compiled in {time.time()-t0:.2f}s")

inp = np.random.randn(1, N_IN).astype(np.float32)
for _ in range(10):           # warmup
    cm(inp)
RUNS = 1000
t0 = time.time()
for _ in range(RUNS):
    out = cm(inp)
dt = time.time() - t0
print(f"  {RUNS} NPU inferences in {dt:.3f}s = {RUNS/dt:,.0f} infer/s")
print("  output shape:", out[0].shape)
print("SUCCESS: the model executed on the NPU (Intel AI Boost).")
