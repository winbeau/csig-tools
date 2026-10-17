"""Keep one H200 card busy so it is still there when the onsite run starts.

Holds --gib of device memory as ballast and runs a matmul loop. Exits on
SIGTERM/SIGINT, and unconditionally after --max-hours as a dead-man switch
so a forgotten reservation cannot sit on a shared card forever.
"""
import argparse, os, signal, subprocess, time

p = argparse.ArgumentParser()
g = p.add_mutually_exclusive_group(required=True)
g.add_argument("--uuid", help="GPU UUID, e.g. GPU-0b85...")
g.add_argument("--index", type=int, help="GPU index; resolved to a UUID at startup")
p.add_argument("--gib", type=float, default=110.0, help="device memory to hold")
p.add_argument("--matrix", type=int, default=8192, help="matmul size N (NxN)")
p.add_argument("--max-hours", type=float, default=8.0)
a = p.parse_args()

# Resolve index -> UUID before touching CUDA: indices shift across reboots,
# UUIDs do not, and the onsite run is pinned by UUID too.
uuid = a.uuid or subprocess.run(
    ["nvidia-smi", "--query-gpu=uuid", "--format=csv,noheader", "-i", str(a.index)],
    capture_output=True, text=True, check=True).stdout.strip()

os.environ["CUDA_VISIBLE_DEVICES"] = uuid
import torch

dev = torch.device("cuda:0")
total = torch.cuda.get_device_properties(dev).total_memory / 2**30

stop = False
def _bye(signum, frame):
    global stop
    stop = True
for s in (signal.SIGTERM, signal.SIGINT):
    signal.signal(s, _bye)

A = torch.randn(a.matrix, a.matrix, device=dev, dtype=torch.bfloat16)
B = torch.randn(a.matrix, a.matrix, device=dev, dtype=torch.bfloat16)
held = (A.numel() + B.numel()) * A.element_size() / 2**30

ballast, chunk = [], 2.0
while held + chunk <= a.gib:
    try:
        ballast.append(torch.empty(int(chunk * 2**30), dtype=torch.uint8, device=dev))
    except torch.cuda.OutOfMemoryError:
        break
    held += chunk

print(f"[reserve] {torch.cuda.get_device_name(dev)} {uuid}", flush=True)
print(f"[reserve] holding {held:.1f} of {total:.1f} GiB, matmul {a.matrix}^2 bf16, "
      f"releases automatically after {a.max_hours} h", flush=True)

t0 = time.time()
deadline = t0 + a.max_hours * 3600
iters = 0
next_log = t0 + 60          # once a minute: enough to see it is alive, no log spam
while not stop and time.time() < deadline:
    C = A @ B
    iters += 1
    if time.time() >= next_log:
        torch.cuda.synchronize()
        now = time.time()
        print(f"[reserve] alive {(now - t0)/60:.0f} min, {iters} matmuls, "
              f"{torch.cuda.memory_allocated(dev)/2**30:.1f} GiB held", flush=True)
        next_log = now + 60

torch.cuda.synchronize()
print(f"[reserve] released after {(time.time() - t0)/60:.1f} min "
      f"({'signal' if stop else 'max-hours'})", flush=True)
