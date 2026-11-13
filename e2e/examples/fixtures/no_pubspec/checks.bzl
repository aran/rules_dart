"""Assertions about what this workspace's targets carry.

`pub_graph_check` fails analysis (so `bazel build //...` fails) when the target
it names does not carry the stated package, version or direct dependencies.
Building it is the test. `fix_changes` hands on the fixes computed for a
target, for a `diff_test` against a golden.
"""

load("@rules_dart//dart:analyze.bzl", "dart_analyze")
load("@rules_dart//dart:providers.bzl", "DartInfo")

def _impl(ctx):
    info = ctx.attr.target[DartInfo]
    label = str(ctx.attr.target.label)
    direct = {name: True for names in info.deps.values() for name in names}
    versions = {}
    for pkg in info.transitive_packages.to_list():
        versions.setdefault(pkg.package_name, {})[pkg.version] = True

    problems = []
    for dep in ctx.attr.direct_deps:
        if dep not in direct:
            problems.append("%s lacks a direct dependency on package `%s` (has: %s)" % (label, dep, sorted(direct.keys())))
    for name, want in ctx.attr.versions.items():
        got = sorted(versions.get(name, {}).keys())
        if got != [want]:
            problems.append("%s resolves package `%s` at %s, expected only [%s]" % (label, name, got, want))
    if problems:
        fail("\n".join(problems))

    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

pub_graph_check = rule(
    implementation = _impl,
    attrs = {
        "target": attr.label(mandatory = True, providers = [DartInfo]),
        "direct_deps": attr.string_list(doc = "Package names the target must depend on directly."),
        "versions": attr.string_dict(doc = "package name -> the one version it must resolve to in the target's closure."),
    },
)

def _fix_changes_impl(ctx):
    groups = ctx.attr.target[OutputGroupInfo]
    if not hasattr(groups, "dart_fix_changes"):
        fail("%s: the dart_analyze aspect offers no fixes for %s" % (ctx.label, ctx.attr.target.label))
    return [DefaultInfo(files = groups.dart_fix_changes)]

# The fixes `bazel run @rules_dart//dart/fix` would write for `target`, as the
# changes file the `dart_analyze` aspect computes.
fix_changes = rule(
    implementation = _fix_changes_impl,
    attrs = {"target": attr.label(mandatory = True, aspects = [dart_analyze])},
)
