"""Generate package_config.json from the transitive DartInfo dependency graph.

This is a standalone rule for generating package_config.json. The dart_binary
rule generates its own package_config inline and does not use this rule.
This rule is useful for custom build scenarios.
"""

load("//dart:providers.bzl", "DartInfo", "DartPackageConfigInfo")

def _generate_package_config_impl(ctx):
    # Collect all unique packages from transitive deps
    packages = []
    seen = {}
    for dep in ctx.attr.deps:
        info = dep[DartInfo]
        for pkg in info.transitive_packages.to_list():
            if pkg.package_name not in seen:
                seen[pkg.package_name] = True
                packages.append(pkg)

    out = ctx.actions.declare_file(ctx.attr.name + ".package_config.json")

    depth = len(out.dirname.split("/"))
    prefix = "/".join([".."] * depth)

    if not packages:
        content = '{"configVersion": 2, "packages": []}\n'
    else:
        entries = []
        for pkg in packages:
            root_uri = prefix + "/" + pkg.lib_root if pkg.lib_root else prefix
            entries.append(
                '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"}}'.format(
                    name = pkg.package_name,
                    root_uri = root_uri,
                ),
            )
        content = '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
            packages = ",\n".join(entries),
        )

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
