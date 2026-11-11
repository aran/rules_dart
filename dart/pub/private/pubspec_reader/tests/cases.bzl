"""Reads every pubspec under testdata/ with the reader, as a package repository does.

`results.json` maps each file's name to what `run_pubspec_reader` returned for
it, read as package "x": `{"error": message}` or `{"ok": {name, dependencies,
sdk_constraint, language_version, fields}}`. `reader_test.dart` checks it against `package:yaml`.
"""

load("//dart/pub/private/pubspec_reader:reader.bzl", "run_pubspec_reader")

visibility("//dart/...")

def _cases_impl(rctx):
    testdata = rctx.path(Label("//dart/pub/private/pubspec_reader/tests:BUILD.bazel")).dirname.get_child("testdata")
    rctx.watch_tree(testdata)
    results = {}
    for case in sorted(testdata.readdir(), key = lambda p: p.basename):
        rctx.symlink(case, case.basename)
        result = run_pubspec_reader(rctx, case.basename, "x")
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
            }}
    rctx.file("results.json", json.encode_indent(results) + "\n")
    rctx.file("BUILD.bazel", 'exports_files(["results.json"])\n')
    return rctx.repo_metadata(reproducible = True)

_cases = repository_rule(implementation = _cases_impl)

def _ext_impl(mctx):
    _cases(name = "pubspec_reader_cases")
    return mctx.extension_metadata(reproducible = True)

pubspec_reader_cases = module_extension(implementation = _ext_impl)
