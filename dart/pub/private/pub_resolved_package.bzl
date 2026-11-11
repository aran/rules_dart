"""A locked package that `pub.from_lock(resolve = ...)` maps to a workspace target.

The mapped package's library repository holds one of these in place of a
`pub_library`: the hub's label and every locked package that depends on the
package reach the workspace target through it. A repository rule cannot see
providers, so whether the target is the package the lock names is checked
here, at analysis.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerInfo")

# Loaded by the BUILD files rules_dart writes into the repositories the `pub`
# extension creates, which are other repositories.
visibility("public")

def _pub_resolved_package_impl(ctx):
    actual = ctx.attr.actual
    info = actual[DartInfo]
    names = [p.package_name for p in info.packages]
    if ctx.attr.package_name not in names:
        fail(
            ("pub.from_lock(): `resolve` maps package `%s` to %s, which is %s. " +
             "Map `%s` to the target that builds that package.") % (
                ctx.attr.package_name,
                actual.label,
                "the Dart package `%s`" % "`, `".join(names) if names else "no Dart package",
                ctx.attr.package_name,
            ),
        )
    providers = [actual[DefaultInfo], info]
    if DartTestRunnerInfo in actual:
        providers.append(actual[DartTestRunnerInfo])
    return providers

pub_resolved_package = rule(
    implementation = _pub_resolved_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The package the lock names."),
        "actual": attr.label(
            mandatory = True,
            providers = [DartInfo],
            doc = "The workspace target that serves it.",
        ),
    },
    doc = "Passes on the target a locked package is mapped to, once it is that package.",
)
