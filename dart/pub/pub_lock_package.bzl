"""Repository rule that downloads a single package from a pubspec.lock.

Each hosted package gets its own external repository (spoke), with the hub
repo providing aliases for backward-compatible `@hub//:pkg` labels.

Also re-exports public Starlark helpers for other Bazel rule sets (notably
rules_flutter's `flutter_pub_package`, the `flutter pub get` analog):
`fetch_pub_archive` (with `check_pub_archive_sha256`) fetches a hosted package
exactly as rules_dart's own pub rules do, and `make_dart_library_build_content`
emits the same `dart_library` shape for non-plugin packages.
"""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _make_dart_library_build_content = "make_dart_library_build_content")
load("//dart/pub/private:language_version.bzl", _derive_language_version = "derive_language_version")
load("//dart/pub/private:pub_archive.bzl", _check_pub_archive_sha256 = "check_pub_archive_sha256", _fetch_pub_archive = "fetch_pub_archive")

# Re-export for consumers outside //dart/pub (rules_flutter's
# flutter_pub_package). Loading the private bzl directly would trip
# buildifier's bzl-visibility check, so we expose it via this public file.
derive_language_version = _derive_language_version
make_dart_library_build_content = _make_dart_library_build_content
fetch_pub_archive = _fetch_pub_archive
check_pub_archive_sha256 = _check_pub_archive_sha256

def _pub_lock_package_impl(ctx):
    fetch_pub_archive(
        ctx,
        package_name = ctx.attr.package_name,
        version = ctx.attr.version,
        sha256 = ctx.attr.sha256,
        base_url = ctx.attr.base_url,
    )

    # Read pubspec.yaml to discover deps + the package's SDK constraint, the
    # latter so we can mirror pub's per-package languageVersion behaviour.
    bazel_deps = []
    language_version = ""
    pubspec_path = ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        pubspec_content = ctx.read(pubspec_path)
        all_deps = parse_pubspec_deps(pubspec_content)
        available = {p: True for p in ctx.attr.lock_packages + ctx.attr.explicit_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])
        language_version = _derive_language_version(
            parse_pubspec_sdk_constraint(pubspec_content),
        )

    # Build full label strings for sibling spoke repos; a package declared
    # with `pub.package()` is its own repository, which wins over the locks.
    explicit = {p: True for p in ctx.attr.explicit_packages}
    dep_labels = [
        ("@{dep}//:{dep}" if dep in explicit else "@{hub}__{dep}//:{dep}").format(hub = ctx.attr.hub_name, dep = dep)
        for dep in bazel_deps
    ]

    # A package that builds native code declares a build hook. rules_dart
    # cannot run it, so unless a curated `dart_code_asset` replaces it — or the
    # user has declared it irrelevant — record it for the consuming binary to
    # complain about. Recording rather than failing here is deliberate: the
    # whole lock is materialised, including packages nothing depends on. A link
    # hook is recorded too, for `dart_link_hook` to run.
    hooks = _classify_pub_hooks(
        has_build_hook = ctx.path("hook/build.dart").exists,
        has_link_hook = ctx.path("hook/link.dart").exists,
        build_hook_handled = bool(ctx.attr.code_assets) or ctx.attr.ignore_hook,
    )

    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = language_version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = hooks.unreplaced_hook,
        version = ctx.attr.version,
        link_hook = hooks.link_hook,
    )

    ctx.file("BUILD.bazel", build_content)
    return ctx.repo_metadata(reproducible = True)

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
            doc = "SHA256 hash of the package archive, as pubspec.lock records it.",
            mandatory = True,
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
        "explicit_packages": attr.string_list(
            doc = "Packages declared with `pub.package()`, which replace any lock's version: a dependency on one is a dependency on its own repository.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Suppress the unreplaced-hook diagnostic for this package. Set by " +
                  "`pub.from_lock(ignore_hooks = [...])`; never a default.",
            default = False,
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets replacing this package's " +
                  "`hook/build.dart` output. Resolved by the `pub` extension from " +
                  "rules_dart's curated registry; attached to the generated " +
                  "`dart_library` so they propagate to every consumer.",
            default = [],
        ),
    },
    doc = "Downloads a single hosted package from a pubspec.lock and generates a BUILD file.",
)
