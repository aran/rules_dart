"""Hub repository rule for pubspec.lock packages.

Generates a BUILD file with aliases from each package name to its
spoke repository: `@hub//:pkg` → `@hub__pkg//:pkg`. A package also declared
with `pub.package()` aliases to that explicit repository instead, `@pkg//:pkg`,
which is the one repository the name means in this build.
"""

def _pub_lock_hub_impl(ctx):
    spoke_prefix = ctx.attr.spoke_prefix if ctx.attr.spoke_prefix else ctx.attr.hub_name
    explicit = {pkg: True for pkg in ctx.attr.explicit_packages}
    aliases = []
    for pkg in ctx.attr.packages:
        if pkg in explicit:
            actual = "@{pkg}//:{pkg}".format(pkg = pkg)
        else:
            actual = "@{spoke}__{pkg}//:{pkg}".format(pkg = pkg, spoke = spoke_prefix)
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            actual = actual,
        ))
    ctx.file("BUILD.bazel", "\n\n".join(aliases) + "\n")

pub_lock_hub = repository_rule(
    implementation = _pub_lock_hub_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The apparent name of this hub repo (for constructing spoke labels).",
            mandatory = True,
        ),
        "spoke_prefix": attr.string(
            doc = "Prefix for spoke repo names. If empty, defaults to hub_name.",
            default = "",
        ),
        "packages": attr.string_list(
            doc = "All hosted package names to create aliases for.",
            mandatory = True,
        ),
        "explicit_packages": attr.string_list(
            doc = "Names in `packages` that are also declared with `pub.package()`. " +
                  "Each aliases to that explicit repository rather than a spoke.",
            default = [],
        ),
    },
    doc = "Creates a hub repo with aliases pointing to individual spoke package repos.",
)
