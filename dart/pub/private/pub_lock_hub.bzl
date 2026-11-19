"""Hub repository rule for pubspec.lock packages.

Generates a BUILD file with an alias for each package a hub's locks name,
`@hub//:pkg`, to the library that supplies it: its `pub.from_lock()` library
repository, or the repository a `pub.package()` declaration made.
"""

visibility("//dart/...")

def _pub_lock_hub_impl(ctx):
    aliases = []
    for pkg, actual in sorted(ctx.attr.packages.items()):
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)""".format(pkg = pkg, actual = actual))
    ctx.file("BUILD.bazel", "\n\n".join(aliases) + "\n")
    ctx.file("versions.json", json.encode({pkg: ctx.attr.versions.get(pkg, "") for pkg in ctx.attr.packages}))

    # Canonical labels: naming a repository does not fetch it.
    ctx.file("sources.json", json.encode({pkg: str(label) for pkg, label in ctx.attr.sources.items()}))

    # Its contents are its attributes', so a new output base takes it from
    # the repository contents cache.
    return ctx.repo_metadata(reproducible = True)

pub_lock_hub = repository_rule(
    implementation = _pub_lock_hub_impl,
    attrs = {
        "packages": attr.string_dict(
            doc = "Each package name to alias, with the label of the library supplying it.",
            mandatory = True,
        ),
        "versions": attr.string_dict(doc = "The version the build has of each package with one, for `versions.json`."),
        "sources": attr.string_keyed_label_dict(doc = "A file of each fetched package's source repository, for `sources.json`: what reads it can follow the packages' dependencies."),
    },
    doc = "Creates a hub repo with aliases pointing to the libraries supplying its packages.",
)
