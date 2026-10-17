"""Generates a synthetic rules_dart benchmark workspace.

N packages, each with F library files; pkg_i depends on pkg_{i-1} and pkg_{i-2}.
One package:test test per package, plus one exe binary at the top.
"""
import os, sys, shutil

out, n_pkgs, n_files = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rules = sys.argv[4]
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)

def w(path, s):
    p = os.path.join(out, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(s)

w("MODULE.bazel", f'''module(name = "bench")

bazel_dep(name = "rules_dart", version = "0.0.0")
local_path_override(module_name = "rules_dart", path = "{rules}")

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.5")
use_repo(dart, "dart_toolchains")
register_toolchains("@dart_toolchains//:all")

pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(name = "pub_deps", lock = "//:pubspec.lock")
use_repo(pub, "pub_deps")
''')
shutil.copy(f"{rules}/e2e/dart_test_pkg/pubspec.lock", os.path.join(out, "pubspec.lock"))
w(".bazelversion", open(f"{rules}/.bazelversion").read())
w(".bazelrc", '''common --lockfile_mode=off
common --@rules_dart//dart:analysis_config=//:analysis_config
build:lint --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
build:lint --output_groups=+dart_analyze
build:lint --output_groups=+dart_format
try-import %workspace%/.bazelrc.user
''')
w("analysis_options.yaml", "analyzer:\n  language:\n    strict-casts: true\n")
w("BUILD.bazel", '''load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options", "dart_binary")

exports_files(["pubspec.lock"])

dart_analysis_options(name = "options", src = "analysis_options.yaml")

dart_analysis_config(name = "analysis_config", options = [":options"])

dart_binary(
    name = "app",
    main = "bin/app.dart",
    deps = ["//packages/pkg%d"],
)
''' % (n_pkgs - 1))
w("bin/app.dart", f"import 'package:pkg{n_pkgs-1}/pkg{n_pkgs-1}.dart';\n\nvoid main() {{\n  print(entry{n_pkgs-1}(3));\n}}\n")

def lib_file(p, f):
    deps = [d for d in (p - 1, p - 2) if d >= 0]
    imports = "".join(f"import 'package:pkg{d}/pkg{d}.dart';\n" for d in deps)
    lines = [imports, f"/// Class {f} of package {p}.", f"class C{p}x{f} {{",
             f"  /// Creates the value holder.", f"  C{p}x{f}(this.value);", "",
             "  /// The value.", "  final int value;", ""]
    for m in range(20):
        lines += [f"  /// Method {m}.", f"  int m{m}(int x) {{",
                  f"    final list = <int>[for (var i = 0; i < x; i++) i * {m + 1}];",
                  "    return list.fold(value, (a, b) => a + b);", "  }", ""]
    lines += ["}", "", f"/// Entry {f}.", f"int fn{p}x{f}(int x) {{"]
    body = (" + ".join([f"[entry{d}].length" for d in deps])) if deps else "x"
    lines += [f"  return C{p}x{f}(x).m3(x) + {body};", "}", ""]
    return "\n".join(lines)

for p in range(n_pkgs):
    base = f"packages/pkg{p}"
    deps = [d for d in (p - 1, p - 2) if d >= 0]
    for f in range(n_files):
        w(f"{base}/lib/src/f{f}.dart", lib_file(p, f))
    exports = "".join(f"export 'src/f{f}.dart';\n" for f in range(n_files))
    imports = "".join(f"import 'src/f{f}.dart';\n" for f in range(n_files))
    w(f"{base}/lib/pkg{p}.dart", exports + "\n" + imports +
      f"\n/// Entry point of package {p}.\nint entry{p}(int x) => " +
      " + ".join(f"fn{p}x{f}(x)" for f in range(n_files)) + ";\n")
    w(f"{base}/test/pkg{p}_test.dart",
      f"import 'package:pkg{p}/pkg{p}.dart';\nimport 'package:test/test.dart';\n\n"
      f"void main() {{\n  test('entry', () {{\n    expect(entry{p}(1), isPositive);\n  }});\n}}\n")
    dep_labels = "".join(f'        "//packages/pkg{d}",\n' for d in deps)
    w(f"{base}/BUILD.bazel", f'''load("@rules_dart//dart:defs.bzl", "dart_library", "dart_test")

dart_library(
    name = "pkg{p}",
    srcs = glob(["lib/**/*.dart"]),
    language_version = "3.9",
    visibility = ["//visibility:public"],
    deps = [
{dep_labels}    ],
)

dart_test(
    name = "pkg{p}_test",
    size = "small",
    main = "test/pkg{p}_test.dart",
    deps = [
        ":pkg{p}",
        "@pub_deps//:test",
    ],
)
''')
print("generated", out)
