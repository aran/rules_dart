"""Repository rule for downloading a single pub.dev package."""

def _pub_package_impl(ctx):
    url = "https://pub.dev/api/archives/{name}-{version}.tar.gz".format(
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )

    ctx.download_and_extract(
        url = url,
        sha256 = ctx.attr.sha256 if ctx.attr.sha256 else "",
        type = "tar.gz",
    )

    # Generate BUILD.bazel with a dart_library target
    dep_labels = ['        "@{dep}",'.format(dep = dep) for dep in ctx.attr.deps]
    deps_block = ""
    if dep_labels:
        deps_block = "    deps = [\n{deps}\n    ],\n".format(
            deps = "\n".join(dep_labels),
        )

    build_content = """\
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
{deps}    visibility = ["//visibility:public"],
)
""".format(
        name = ctx.attr.package_name,
        deps = deps_block,
    )

    ctx.file("BUILD.bazel", build_content)

pub_package = repository_rule(
    implementation = _pub_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub.dev package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive for integrity verification. Optional.",
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
    },
    doc = "Downloads a pub.dev package and generates a dart_library BUILD target.",
)
