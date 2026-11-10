"""Repository rule for downloading a single pub.dev package."""

load("//dart/pub:pubspec.bzl", "read_pubspec")
load("//dart/pub/private:build_content.bzl", "find_pub_license_file", "make_dart_library_build_content")
load("//dart/pub/private:pub_archive.bzl", "fetch_pub_archive")

def _pub_package_impl(ctx):
    fetch_pub_archive(
        ctx,
        package_name = ctx.attr.package_name,
        version = ctx.attr.version,
        sha256 = ctx.attr.sha256,
    )

    # Read the package's pubspec.yaml so we can mirror pub's per-package
    # languageVersion behaviour. This lets the analyzer apply the right
    # language semantics for packages whose SDK floor predates the running
    # Dart SDK (e.g. `state_notifier` with `sdk: ">=2.12.0"`).
    pubspec = read_pubspec(ctx, ctx.attr.package_name, ctx.attr.version)
    language_version = pubspec.language_version

    # Generate BUILD.bazel with a dart_library target. `deps` here names sibling
    # repositories, whose default target carries the repo's own name.
    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = ["@{dep}".format(dep = dep) for dep in ctx.attr.deps],
        language_version = language_version,
        version = ctx.attr.version,
        # A link hook is runnable by `dart_link_hook`, so it is recorded.
        link_hook = "hook/link.dart" if ctx.path("hook/link.dart").exists else "",
        license_file = find_pub_license_file(ctx),
    )

    ctx.file("BUILD.bazel", build_content)
    return ctx.repo_metadata(reproducible = True)

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
            doc = "SHA256 hash of the package archive, as pubspec.lock records it.",
            mandatory = True,
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
    },
    doc = "Downloads a pub.dev package and generates a dart_library BUILD target.",
)
