"""The `dart_analysis_test` rule: the `dart_analyze` aspect's checks for named targets.

The normal way to check a repository is the `.bazelrc` setup in
`dart_analyze_aspect.bzl`, which applies the aspect to every target a test run
names. That cannot reach a target `bazel test //...` skips — one tagged
`manual`, a fixture that must never be built on its own. This rule applies the
same aspect to the targets it lists, through its attribute, so they are checked
whenever the test is.

The verdict is reached in the build, like the command-line aspect's: the test's
runfiles carry the stamps the aspect's actions write only on success, so a
diagnostic or a formatting violation fails the build of this test, and the test
binary itself passes through.
"""

load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "noop_test_executable")
load("//dart/private:dart_analyze_aspect.bzl", "NO_ANALYZE_TAG", "NO_FORMAT_TAG", "dart_analyze")

_CHECKS = ["dart_analyze", "dart_format"]

def _dart_analysis_test_impl(ctx):
    stamps = []
    for target in ctx.attr.targets:
        groups = target[OutputGroupInfo] if OutputGroupInfo in target else None
        checks = [getattr(groups, g) for g in _CHECKS if groups != None and hasattr(groups, g)]
        if not checks:
            fail(("%s: lists %s, which the `dart_analyze` aspect has nothing to " +
                  "check in: it is not a Dart target, has no hand-written " +
                  "source of its own, or is tagged both `%s` and `%s`. Drop it " +
                  "from `targets`.") % (ctx.label, target.label, NO_ANALYZE_TAG, NO_FORMAT_TAG))
        stamps.extend(checks)
    noop = noop_test_executable(ctx, ctx.attr._tool)
    return [DefaultInfo(
        executable = noop.executable,
        runfiles = ctx.runfiles(transitive_files = depset(transitive = stamps)).merge(noop.runfiles),
    )]

dart_analysis_test = rule(
    implementation = _dart_analysis_test_impl,
    attrs = dict({
        "targets": attr.label_list(
            doc = "The Dart targets to check. Each gets both checks — analysis and the format check — less any its `no-dart-analyze` or `no-dart-format` tag removes.",
            aspects = [dart_analyze],
            allow_empty = False,
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:noop",
            executable = True,
            cfg = "exec",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    test = True,
    doc = """Runs the `dart_analyze` aspect's checks on targets `bazel test //...` cannot reach.

For a target tagged `manual`, or a fixture that must not be built by a
wildcard, list it here: the test fails to build if `dart analyze` reports
anything in the target's own files, or if `dart format` would change one. Both
checks run on every listed target, less whatever its `no-dart-analyze` or
`no-dart-format` tag removes, under the options the
`@rules_dart//dart:analysis_config` flag names — the same flag, and the same
aspect, as the `.bazelrc` setup.

This is not the way to enable the checks. The `.bazelrc` setup checks every
Dart target a test run names; this rule is only for targets that setup cannot
name.

```starlark
dart_analysis_test(
    name = "fixtures_analysis_test",
    targets = [":manual_fixture"],
)
```""",
)
