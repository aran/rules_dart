"""Hub repository rule for pubspec.lock packages.

Generates a BUILD file with aliases from each package name to its
spoke repository: `@hub//:pkg` → `@hub__pkg//:pkg`.
"""

def _pub_lock_hub_impl(ctx):
    aliases = []
    for pkg in ctx.attr.packages:
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "@{hub}__{pkg}//:{pkg}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            hub = ctx.attr.hub_name,
        ))
    ctx.file("BUILD.bazel", "\n\n".join(aliases) + "\n")

pub_lock_hub = repository_rule(
    implementation = _pub_lock_hub_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The apparent name of this hub repo (for constructing spoke labels).",
            mandatory = True,
        ),
        "packages": attr.string_list(
            doc = "All hosted package names to create aliases for.",
            mandatory = True,
        ),
    },
    doc = "Creates a hub repo with aliases pointing to individual spoke package repos.",
)
