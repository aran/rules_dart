"""Hub repository rule for pubspec.lock packages.

Generates a BUILD file with aliases from each package name to its
spoke repository: `@hub//:pkg` → `@hub__pkg//:pkg`.
"""

def _pub_lock_hub_impl(ctx):
    spoke_prefix = ctx.attr.spoke_prefix if ctx.attr.spoke_prefix else ctx.attr.hub_name
    aliases = []
    for pkg in ctx.attr.packages:
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "@{spoke}__{pkg}//:{pkg}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            spoke = spoke_prefix,
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
    },
    doc = "Creates a hub repo with aliases pointing to individual spoke package repos.",
)
