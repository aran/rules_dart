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

    # pub.dev serves some tarballs with trailing garbage past the gzip
    # stream (observed as of 2026-04 on `nested@1.0.0`, among others).
    # Bazel's built-in `download_and_extract` uses a strict Java gzip
    # decoder that errors on the trailing bytes — but the archive itself
    # is a valid tar.gz (GNU `tar -xzf` accepts it, `gunzip -t` reports
    # "trailing garbage ignored").
    #
    # We download the archive, then extract with the system `tar`
    # command, which tolerates the trailing bytes. The sha256 still
    # verifies the download so integrity is preserved.
    ctx.download(
        url = url,
        output = "_archive.tar.gz",
        sha256 = ctx.attr.sha256 if ctx.attr.sha256 else "",
    )
    result = ctx.execute(["tar", "-xzf", "_archive.tar.gz"])
    if result.return_code != 0:
        fail("tar -xzf failed for {url}:\nstdout: {out}\nstderr: {err}".format(
            url = url,
            out = result.stdout,
            err = result.stderr,
        ))
    ctx.delete("_archive.tar.gz")

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

    # `allow_empty = True` lets resource-only (e.g. cupertino_icons:
    # icon font assets) and platform-plugin packages (e.g. record_ios:
    # Swift-only; Dart glue lives in the umbrella package) produce an
    # empty dart_library rather than failing the glob. Consumers that
    # depend on such a package via `@deps//:foo` still resolve: the
    # empty target contributes nothing to DartInfo, and the real
    # (resource / native) artifacts flow through separate pipelines.
    build_content = """\
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
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
