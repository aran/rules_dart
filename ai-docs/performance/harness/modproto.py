"""Hand-run modular kernel compilation over the bench packages (no Bazel)."""
import json, os, subprocess, sys, time, glob
S, mode = sys.argv[1], sys.argv[2]   # mode: full | leafedit
SDK = sys.argv[3]
bench, out = f"{S}/bench", f"{S}/modproto"
N = 30
pc = {"configVersion": 2, "packages": [
    {"name": f"pkg{p}", "rootUri": f"{bench}/packages/pkg{p}", "packageUri": "lib/", "languageVersion": "3.9"} for p in range(N)]}
json.dump(pc, open(f"{out}/package_config.json", "w"))
kw = [f"{SDK}/bin/dartaotruntime", f"{SDK}/bin/snapshots/kernel_worker_aot.dart.snapshot"]
plat = f"{SDK}/lib/_internal/vm_platform_strong.dill"
def run(args):
    t = time.time(); r = subprocess.run(kw + args, capture_output=True, text=True)
    if r.returncode: print(r.stdout, r.stderr); sys.exit(1)
    return time.time() - t
def deps(p): return [d for d in (p - 1, p - 2) if d >= 0]
def closure(p):
    s, todo = set(), [p]
    while todo:
        q = todo.pop()
        for d in deps(q):
            if d not in s: s.add(d); todo.append(d)
    return sorted(s)
tot_o = tot_f = 0
pkgs = range(N) if mode == "full" else [0]
for p in pkgs:
    srcs = sorted(glob.glob(f"{bench}/packages/pkg{p}/lib/**/*.dart", recursive=True))
    uris = [f"package:pkg{p}/" + os.path.relpath(s, f"{bench}/packages/pkg{p}/lib") for s in srcs]
    common = ["--target", "vm", "--dart-sdk-summary", plat, "--packages-file", f"{out}/package_config.json", "--exclude-non-sources"]
    for d in closure(p): common += ["--input-summary", f"{out}/pkg{d}.outline.dill"]
    for u in uris: common += ["--source", u]
    tot_o += run(common + ["--summary-only", "--output", f"{out}/pkg{p}.outline.dill"])
    tot_f += run(common + ["--no-summary-only", "--output", f"{out}/pkg{p}.dill"])
print(f"{mode}: outlines {tot_o:.2f}s, full modules {tot_f:.2f}s over {len(pkgs)} pkgs")
# The 'test' for pkg29: a main module against all outlines, then link by concatenation.
open(f"{out}/main.dart", "w").write("import 'package:pkg29/pkg29.dart';\nvoid main() { print(entry29(1)); }\n")
args = ["--target", "vm", "--dart-sdk-summary", plat, "--packages-file", f"{out}/package_config.json", "--exclude-non-sources", "--no-summary-only", "--source", f"{out}/main.dart", "--output", f"{out}/main.dill"]
for d in range(N): args += ["--input-summary", f"{out}/pkg{d}.outline.dill"]
tm = run(args)
t = time.time()
with open(f"{out}/app.dill", "wb") as w:
    for f in [f"{out}/pkg{d}.dill" for d in range(N)] + [f"{out}/main.dill"]: w.write(open(f, "rb").read())
tl = time.time() - t
t = time.time(); r = subprocess.run([f"{SDK}/bin/dart", f"{out}/app.dill"], capture_output=True, text=True); tr = time.time() - t
print(f"main module {tm:.2f}s, link(cat) {tl*1000:.0f}ms, run {tr:.2f}s -> {r.stdout.strip()} {r.stderr.strip()[:300]}")
t = time.time(); r = subprocess.run([f"{SDK}/bin/dart", "compile", "kernel", "--packages", f"{out}/package_config.json", "-o", f"{out}/mono.dill", f"{out}/main.dart"], capture_output=True, text=True, env={**os.environ, "HOME": "/tmp"});
print(f"monolithic dart compile kernel: {time.time()-t:.2f}s rc={r.returncode}")
