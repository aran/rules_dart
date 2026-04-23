"""Repository rule that downloads a single package from a pubspec.lock.

Each hosted package gets its own external repository (spoke), with the hub
repo providing aliases for backward-compatible `@hub//:pkg` labels.
"""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//dart/pub/private:language_version.bzl", "derive_language_version")

def _pub_lock_package_impl(ctx):
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = ctx.attr.base_url,
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )
    ctx.download_and_extract(
        url = url,
        sha256 = ctx.attr.sha256 if ctx.attr.sha256 else "",
        type = "tar.gz",
    )

    # Read pubspec.yaml to discover deps + the package's SDK constraint, the
    # latter so we can mirror pub's per-package languageVersion behaviour.
    bazel_deps = []
    language_version = ""
    pubspec_path = ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        pubspec_content = ctx.read(pubspec_path)
        all_deps = parse_pubspec_deps(pubspec_content)
        available = {p: True for p in ctx.attr.lock_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])
        language_version = derive_language_version(
            parse_pubspec_sdk_constraint(pubspec_content),
        )

    # Build dep labels pointing to sibling spoke repos
    dep_labels = ['        "@{hub}__{dep}//:{dep}",'.format(
        hub = ctx.attr.hub_name,
        dep = dep,
    ) for dep in bazel_deps]

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
{deps}    package_name = "{name}",
    language_version = "{language_version}",
    visibility = ["//visibility:public"],
)
""".format(
        name = ctx.attr.package_name,
        deps = deps_block,
        language_version = language_version,
    )

    ctx.file("BUILD.bazel", build_content)

pub_lock_package = repository_rule(
    implementation = _pub_lock_package_impl,
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
            doc = "SHA256 hash of the package archive.",
            default = "",
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository.",
            default = "https://pub.dev",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All hosted package names in the lock file (for dep filtering).",
            default = [],
        ),
    },
    doc = "Downloads a single hosted package from a pubspec.lock and generates a BUILD file.",
)
