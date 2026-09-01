"""Repository rule for downloading a single pub.dev package."""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_sdk_constraint")
load("//dart/pub/private:build_content.bzl", "make_dart_library_build_content")
load("//dart/pub/private:language_version.bzl", "derive_language_version")

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

    # Read the package's pubspec.yaml so we can mirror pub's per-package
    # languageVersion behaviour. This lets the analyzer apply the right
    # language semantics for packages whose SDK floor predates the running
    # Dart SDK (e.g. `state_notifier` with `sdk: ">=2.12.0"`).
    pubspec_content = ctx.read("pubspec.yaml")
    sdk_constraint = parse_pubspec_sdk_constraint(pubspec_content)
    language_version = derive_language_version(sdk_constraint)

    # Generate BUILD.bazel with a dart_library target. `deps` here names sibling
    # repositories, whose default target carries the repo's own name.
    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = ["@{dep}".format(dep = dep) for dep in ctx.attr.deps],
        language_version = language_version,
        version = ctx.attr.version,
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
