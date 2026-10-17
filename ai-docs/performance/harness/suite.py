"""rules_dart benchmark suite. Usage: suite.py <rules_dart checkout> <label> [scenarios...]

Generates fresh bench workspaces against the given checkout, runs each scenario,
writes results/<label>.json and prints a table.
"""
import gzip, json, os, re, subprocess, sys, time, collections, statistics
S = os.environ.get("RULES_DART_BENCH_DIR", os.path.expanduser("~/rules_dart_bench"))
BZ = f"{S}/tools/bzb"
rules, label = sys.argv[1], sys.argv[2]
only = set(sys.argv[3:])
os.makedirs(f"{S}/results", exist_ok=True)
SDK_GLOB = "external/rules_dart++dart+dart_linux-x64"

def sh(cmd, cwd, check=True):
    t = time.time()
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    dt = time.time() - t
    if check and r.returncode not in (0, 4):
        print(r.stdout[-3000:], r.stderr[-3000:]); raise SystemExit(f"failed: {cmd}")
    return dt, r.stdout + r.stderr

def procs(out):
    m = re.search(r"INFO: (\d+) processes: .*?(\d+) linux-sandbox", out)
    return int(m[2]) if m else 0

def prof(path):
    ev = json.load(gzip.open(path))["traceEvents"]
    by = collections.defaultdict(list)
    for e in ev:
        if e.get("ph") == "X" and e.get("cat") == "action processing":
            mn = e.get("args", {}).get("mnemonic") or e["name"].split(" ")[0]
            by[mn].append(e["dur"] / 1e6)
    keep = ("DartCompile", "DartAnalyze", "DartFormat", "CopyToDirectory", "TestRunner", "SymlinkTree",
            "DartGenKernelNativeAssets", "DartKernel", "DartKernelOutline", "DartKernelLink", "DartJitSnapshot")
    return {k: {"n": len(v), "cpu_s": round(sum(v), 2)} for k, v in by.items() if k in keep or k.startswith("Dart")}

def build(ws, args, name):
    p = f"{S}/results/{label}.{name}.json.gz"
    dt, out = sh(f"{BZ} {args} --noslim_profile --profile={p}", ws)
    return {"wall_s": round(dt, 2), "sandboxed": procs(out), "actions": prof(p)}

def gen(name, n, f):
    ws = f"{S}/{name}"
    subprocess.run(["python3", f"{S}/tools/gen_bench.py", ws, str(n), str(f), rules], check=True, capture_output=True)
    sh(f"{BZ} build //... --nobuild", ws)  # fetch
    ob = sh(f"{BZ} info output_base", ws)[1].strip().splitlines()[-1]
    sh(f"HOME={S}/home_fmt {ob}/{SDK_GLOB}/bin/dart format --language-version=3.9 packages bin", ws)
    return ws

def bump(ws):
    subprocess.run(["python3", f"{S}/tools/bump.py", f"{ws}/packages/pkg0/lib/src/f0.dart"], check=True)

def api_edit(ws, on):
    p = f"{ws}/packages/pkg0/lib/src/f0.dart"
    s = open(p).read()
    add = "  /// Added API.\n  int get extra => 1;\n\n"
    s = s.replace("  /// The value.\n", add + "  /// The value.\n", 1) if on else s.replace(add, "", 1)
    open(p, "w").write(s)

res = {"label": label, "rules_rev": sh("git rev-parse --short HEAD", rules)[1].strip(), "scenarios": {}}
R = res["scenarios"]
want = lambda k: not only or k in only

if want("analysis"):
    ws = gen("bench80", 80, 30)
    sh(f"{BZ} build //... --nobuild", ws)
    ts = [sh(f"{BZ} build //... --nobuild --define=bench={label}{i}{time.time()}", ws)[0] for i in range(3)]
    R["reanalysis_80pkg_s"] = round(statistics.median(ts), 2)

ws = gen("bench", 30, 20)
if want("build"):
    sh(f"{BZ} clean", ws)
    R["clean_build"] = build(ws, "build //...", "clean_build")
    bump(ws); R["body_edit_build"] = build(ws, "build //...", "body_edit_build")
    api_edit(ws, True); R["api_edit_build"] = build(ws, "build //...", "api_edit_build")
    api_edit(ws, False); sh(f"{BZ} build //...", ws)
    R["null_build_s"] = round(sh(f"{BZ} build //...", ws)[0], 2)
if want("test"):
    sh(f"{BZ} build //...", ws)
    r = build(ws, "test //... --nocache_test_results", "test")
    tr = r["actions"].get("TestRunner", {"n": 1, "cpu_s": 0})
    r["per_test_s"] = round(tr["cpu_s"] / max(tr["n"], 1), 3)
    R["test_run"] = r
    rf = f"{ws}/bazel-bin/packages/pkg5/pkg5_test.runfiles"
    n = int(sh(f"find -L {rf} -type f | wc -l", ws)[1].split()[-1])
    size = sh(f"du -sLm {rf}", ws)[1].split()[0]
    R["test_runfiles"] = {"files": n, "mb": int(size)}
if want("lint"):
    sh(f"{BZ} clean", ws)
    R["lint_clean"] = build(ws, "build --config=lint //...", "lint_clean")
    bump(ws); R["lint_body_edit"] = build(ws, "build --config=lint //...", "lint_body_edit")

json.dump(res, open(f"{S}/results/{label}.json", "w"), indent=1)
print(json.dumps(res, indent=1))
