"""Replays tool/refresh_locks.dart's Bazel steps through the mirror wrapper."""
import os, subprocess, sys
S = os.environ.get("RULES_DART_BENCH_DIR", os.path.expanduser("~/rules_dart_bench"))
root = sys.argv[1]
wss = sorted({os.path.dirname(os.path.join(d, f)) for d, _, fs in os.walk(root)
              for f in fs if f == "MODULE.bazel" and "/bazel-" not in d and "/references" not in d and "/.claude" not in d})
for ws in wss:
    rel = os.path.relpath(ws, root)
    r1 = subprocess.run([f"{S}/tools/bzl", "mod", "tidy", "--lockfile_mode=refresh"], cwd=ws, capture_output=True, text=True)
    r2 = subprocess.run([f"{S}/tools/bzl", "build", "--nobuild", "--lockfile_mode=update", "//..."], cwd=ws, capture_output=True, text=True)
    ok = r1.returncode == 0 and r2.returncode in (0, 4)
    print(("OK  " if ok else "FAIL"), rel, r1.returncode, r2.returncode)
    if not ok:
        print("\n".join([l for l in (r1.stderr + r2.stderr).splitlines() if "ERROR" in l][:4]))
    subprocess.run([f"{S}/tools/bzl", "shutdown"], cwd=ws, capture_output=True)
