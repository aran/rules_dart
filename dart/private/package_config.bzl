"""Generate package_config.json from the transitive DartInfo dependency graph.

This is a standalone rule for generating package_config.json. The dart_binary
rule generates its own package_config inline and does not use this rule.
This rule is useful for custom build scenarios.
"""

load("//dart:providers.bzl", "DartInfo", "DartPackageConfigInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_srcs", generate_package_config_fn = "generate_package_config")

def _generate_package_config_impl(ctx):
    packages = collect_packages(ctx.attr.deps)
    all_srcs = collect_transitive_srcs(ctx.attr.deps)

    out = ctx.actions.declare_file(ctx.attr.name + ".package_config.json")
    content = generate_package_config_fn(packages, all_srcs, out)
    ctx.actions.write(out, content)

    return [
        DefaultInfo(files = depset([out])),
        DartPackageConfigInfo(file = out),
    ]

generate_package_config = rule(
    implementation = _generate_package_config_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "dart_library targets whose transitive closure forms the package graph.",
            providers = [DartInfo],
        ),
    },
    doc = "Generates a package_config.json file from transitive Dart dependencies.",
)
