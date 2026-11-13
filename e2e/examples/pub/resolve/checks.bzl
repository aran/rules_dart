"""Analysis-time assertions about where `resolve` sends a hub's packages.

`resolved_graph_check` fails analysis (so `bazel build //...` fails) when the
target it names does not depend directly on the stated packages, or reaches a
stated package anywhere but at the stated `package_root`. Building it is the test.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")

def _resolved_graph_check_impl(ctx):
    info = ctx.attr.target[DartInfo]
    label = str(ctx.attr.target.label)
    direct = {name: True for names in info.deps.values() for name in names}
    roots = {}
    for pkg in info.transitive_packages.to_list():
        roots.setdefault(pkg.package_name, {})[pkg.package_root] = True

    problems = []
    for dep in ctx.attr.direct_deps:
        if dep not in direct:
            problems.append("%s lacks a direct dependency on package `%s` (has: %s)" % (label, dep, sorted(direct.keys())))
    for name, want in ctx.attr.package_roots.items():
        got = sorted(roots.get(name, {}).keys())
        if got != [want]:
            problems.append("%s reaches package `%s` at %s, expected only [%s]" % (label, name, got, want))
    if problems:
        fail("\n".join(problems))

    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

resolved_graph_check = rule(
    implementation = _resolved_graph_check_impl,
    attrs = {
        "target": attr.label(mandatory = True, providers = [DartInfo]),
        "direct_deps": attr.string_list(doc = "Package names the target must depend on directly."),
        "package_roots": attr.string_dict(doc = "package name -> the one `package_root` it must have in the target's closure."),
    },
)
