"""Reads every pubspec under testdata/ with the reader, as a package repository does.

`results.json` maps each file's name to what `run_pubspec_reader` returned for
it, read as package "x": `{"error": message}` or `{"ok": {name, dependencies,
sdk_constraint, language_version, unsatisfied, fields}}`. `reader_test.dart` checks it against `package:yaml`.
"""

load("//dart/pub/private/pubspec_reader:reader.bzl", "run_pubspec_reader")

visibility("//dart/...")

# What the constraints of `u01_constraints.yaml` are compared with.
_LOCKED_VERSIONS = {
    "u_any": "9.9.9",
    "u_from_path": "0.1.0",
    "u_in_map": "2.0.0",
    "u_satisfied": "1.5.0",
    "u_too_old": "1.5.0",
}

def _cases_impl(rctx):
    testdata = rctx.path(Label("//dart/pub/private/pubspec_reader/tests:BUILD.bazel")).dirname.get_child("testdata")
    rctx.watch_tree(testdata)
    results = {}
    for case in sorted(testdata.readdir(), key = lambda p: p.basename):
        rctx.symlink(case, case.basename)
        result = run_pubspec_reader(rctx, case.basename, "x", _LOCKED_VERSIONS)
        if result.error != None:
            results[case.basename] = {"error": result.error}
        else:
            p = result.pubspec
            results[case.basename] = {"ok": {
                "dependencies": p.dependencies,
                "fields": p.fields,
                "language_version": p.language_version,
                "name": p.name,
                "sdk_constraint": p.sdk_constraint,
                "unsatisfied": p.unsatisfied,
            }}
    rctx.file("results.json", json.encode_indent(results) + "\n")
    rctx.file("BUILD.bazel", 'exports_files(["results.json"])\n')
    return rctx.repo_metadata(reproducible = True)

_cases = repository_rule(implementation = _cases_impl)

def _ext_impl(mctx):
    _cases(name = "pubspec_reader_cases")
    return mctx.extension_metadata(reproducible = True)

pubspec_reader_cases = module_extension(implementation = _ext_impl)
