"""Repository rule that downloads a single package from a pubspec.lock.

Each hosted package gets its own source repository (spoke), holding its files
and the facts it states about itself as a `pub_package_member`. Which packages
it is built with — its dependency cycle, if pub resolved one — is decided by
its library repository (`pub_lock_library`), which the hub's `@hub//:pkg`
aliases point at.

Also re-exports public Starlark helpers for other Bazel rule sets (notably
rules_flutter's `flutter_pub_package`, the `flutter pub get` analog):
`fetch_pub_archive` (with `check_pub_archive_sha256`) fetches a hosted package
exactly as rules_dart's own pub rules do, and `make_dart_library_build_content`
emits the same `dart_library` shape for non-plugin packages.
"""

load("//dart/pub:pub_graph.bzl", "write_pubspec_dependencies")
load("//dart/pub:pubspec.bzl", "read_pubspec")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _make_dart_library_build_content = "make_dart_library_build_content", _make_pub_member_build_content = "make_pub_member_build_content")
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

    # Read the package's SDK constraint, to mirror pub's per-package
    # languageVersion behaviour, and its dependencies, which it records for
    # its library repository and the library repositories of packages that
    # reach it: parsed once here, not by each.
    language_version = ""
    pubspec_deps = []
    if ctx.path("pubspec.yaml").exists:
        pubspec = read_pubspec(ctx, ctx.attr.package_name, ctx.attr.version)
        language_version = _derive_language_version(pubspec.sdk_constraint)
        pubspec_deps = pubspec.dependencies
    write_pubspec_dependencies(ctx, pubspec_deps)

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

    ctx.file("BUILD.bazel", _make_pub_member_build_content(
        name = ctx.attr.package_name,
        language_version = language_version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = hooks.unreplaced_hook,
        version = ctx.attr.version,
        link_hook = hooks.link_hook,
    ))
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
