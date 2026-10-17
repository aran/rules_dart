"""Builds e2e/ext_exemplar against a rules_dart checkout, without its Gazelle targets.

Usage: ext_exemplar.py <rules_dart checkout> <tag> [bazel flags...]

The workspace's root BUILD.bazel loads @gazelle, whose go_deps extension needs
go.dev. Where go.dev is unreachable, this copies the workspace to
$RULES_DART_BENCH_DIR/ext_<tag>, points local_path_override at the checkout,
strips the gazelle load and targets, builds //... --keep_going, prints the
ERROR lines, and expunges. sqlite.org being unreachable shows up as a
`sqlite3+` fetch error, which is expected there.
"""
import os, re, shutil, subprocess, sys

S = os.environ.get("RULES_DART_BENCH_DIR", os.path.expanduser("~/rules_dart_bench"))
rules, tag, flags = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3:]
src = f"{rules}/e2e/ext_exemplar"
dst = f"{S}/ext_{tag}"
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock"))
m = open(f"{dst}/MODULE.bazel").read().replace('path = "../.."', f'path = "{rules}"')
open(f"{dst}/MODULE.bazel", "w").write(m)
b = open(f"{dst}/BUILD.bazel").read()
b = b.replace('load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")\n', "")
b = re.sub(r"gazelle_binary\(.*?\n\)\n", "", b, flags=re.S)
b = re.sub(r"gazelle\(\n.*?\n\)\n", "", b, flags=re.S)
open(f"{dst}/BUILD.bazel", "w").write(b)
bz = f"{S}/tools/bzb"
r = subprocess.run([bz, "build", "--jobs=3", "--keep_going", *flags, "//..."], cwd=dst, capture_output=True, text=True)
print(f"[{tag} {' '.join(flags)}] build rc={r.returncode}")
print("\n".join(l[:250] for l in (r.stdout + r.stderr).splitlines() if l.startswith("ERROR"))[:4000])
subprocess.run([bz, "clean", "--expunge"], cwd=dst, capture_output=True)
