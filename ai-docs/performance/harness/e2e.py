"""Scratch e2e runner: e2e.py <rules checkout> <workspace>[:<bazel args>] ..."""
import os
import subprocess, sys
S = os.environ.get("RULES_DART_BENCH_DIR", os.path.expanduser("~/rules_dart_bench"))
root, specs = sys.argv[1], sys.argv[2:]
failed = []
for spec in specs:
    ws, _, args = spec.partition(":")
    args = args or "test --test_output=errors //..."
    r = subprocess.run(f"{S}/tools/bzb {args}", cwd=f"{root}/e2e/{ws}", shell=True, capture_output=True, text=True)
    ok = r.returncode in (0, 4)
    print(("OK  " if ok else "FAIL"), ws, args)
    if not ok:
        failed.append(ws)
        print("\n".join([l for l in (r.stdout + r.stderr).splitlines() if "ERROR" in l or "FAIL" in l][:12]))
sys.exit(1 if failed else 0)
