import hashlib, os, sys
from concurrent.futures import ThreadPoolExecutor

root = sys.argv[1]
man = os.path.join(root, "MANIFEST.sha256")

# integrity of the manifest itself
with open(man, "rb") as f:
    man_sha = hashlib.sha256(f.read()).hexdigest()

entries = []
with open(man, encoding="utf-8") as f:
    for ln, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("  ", 2)
        if len(parts) != 3:
            print(f"BAD-MANIFEST-LINE {ln}: {line[:120]}")
            continue
        entries.append((parts[0], int(parts[1]), parts[2]))

def check(e):
    exp_hash, exp_size, rel = e
    p = os.path.join(root, rel)
    try:
        st = os.stat(p)
    except FileNotFoundError:
        return ("MISSING", rel, "")
    if st.st_size != exp_size:
        return ("SIZE", rel, f"{st.st_size} != {exp_size}")
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(8 << 20), b""):
            h.update(chunk)
    got = h.hexdigest()
    if got != exp_hash:
        return ("HASH", rel, f"{got[:16]} != {exp_hash[:16]}")
    return None

bad = []
total = 0
with ThreadPoolExecutor(max_workers=12) as ex:
    for i, r in enumerate(ex.map(check, entries), 1):
        if r:
            bad.append(r)
        if i % 200 == 0:
            print(f"... {i}/{len(entries)} checked, {len(bad)} bad", flush=True)
for _, _, _ in []:
    pass
total = sum(e[1] for e in entries)
print(f"\nmanifest_sha256 = {man_sha}")
print(f"entries = {len(entries)}, bytes = {total} ({total/1e9:.2f} GB)")
if bad:
    print(f"FAILED: {len(bad)} problem(s)")
    for kind, rel, det in bad[:40]:
        print(f"  {kind:8} {rel}  {det}")
else:
    print("RESULT: ALL FILES OK (size + sha256)")
