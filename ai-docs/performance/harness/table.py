import os
import json, sys
S = os.environ.get("RULES_DART_BENCH_DIR", os.path.expanduser("~/rules_dart_bench"))
runs = [json.load(open(f"{S}/results/{l}.json")) for l in sys.argv[1:]]
def g(r, *path):
    v = r["scenarios"]
    for p in path:
        v = v.get(p) if isinstance(v, dict) else None
        if v is None: return "–"
    return v
rows = [
 ("Re-analysis, 80 pkgs (s)", ("reanalysis_80pkg_s",)),
 ("Clean build wall (s)", ("clean_build", "wall_s")),
 ("  compile CPU (s)", ("clean_build", "actions", "DartCompile", "cpu_s")),
 ("Body edit rebuild (s)", ("body_edit_build", "wall_s")),
 ("  compiles re-run", ("body_edit_build", "actions", "DartCompile", "n")),
 ("API edit rebuild (s)", ("api_edit_build", "wall_s")),
 ("Null build (s)", ("null_build_s",)),
 ("Test run wall, 30 tests (s)", ("test_run", "wall_s")),
 ("  per test (s)", ("test_run", "per_test_s")),
 ("Test runfiles (files)", ("test_runfiles", "files")),
 ("Test runfiles (MB)", ("test_runfiles", "mb")),
 ("Lint clean wall (s)", ("lint_clean", "wall_s")),
 ("  sandboxed actions", ("lint_clean", "sandboxed")),
 ("Lint body edit wall (s)", ("lint_body_edit", "wall_s")),
 ("  analyze re-run", ("lint_body_edit", "actions", "DartAnalyze", "n")),
 ("  format re-run", ("lint_body_edit", "actions", "DartFormat", "n")),
 ("  copies re-run (CopyToDirectory)", ("lint_body_edit", "actions", "CopyToDirectory", "n")),
 ("  copies re-run (DartCopyTree)", ("lint_body_edit", "actions", "DartCopyTree", "n")),
]
print("| Metric | " + " | ".join(f"{r['label']} ({r['rules_rev']})" for r in runs) + " |")
print("|---|" + "---|" * len(runs))
for name, path in rows:
    print(f"| {name} | " + " | ".join(str(g(r, *path)) for r in runs) + " |")
