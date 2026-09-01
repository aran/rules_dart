"""Repository rule that downloads a single package from a pubspec.lock.

Each hosted package gets its own external repository (spoke), with the hub
repo providing aliases for backward-compatible `@hub//:pkg` labels.

Also re-exports `make_dart_library_build_content` as a public Starlark
helper. Other Bazel rule sets (notably rules_flutter's `flutter_pub_package`,
the `flutter pub get` analog) reuse this helper to emit the same
`dart_library` shape for non-plugin packages without duplicating the format.
"""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//dart/pub/private:build_content.bzl", _make_dart_library_build_content = "make_dart_library_build_content")
load("//dart/pub/private:language_version.bzl", _derive_language_version = "derive_language_version")

# Re-export for consumers outside //dart/pub (rules_flutter's
# flutter_pub_package). Loading the private bzl directly would trip
# buildifier's bzl-visibility check, so we expose it via this public file.
derive_language_version = _derive_language_version
make_dart_library_build_content = _make_dart_library_build_content

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
        language_version = _derive_language_version(
            parse_pubspec_sdk_constraint(pubspec_content),
        )

    # Build full label strings for sibling spoke repos.
    dep_labels = [
        "@{hub}__{dep}//:{dep}".format(hub = ctx.attr.hub_name, dep = dep)
        for dep in bazel_deps
    ]

    # A package that builds native code declares a hook. rules_dart cannot run
    # it, so unless a curated `dart_code_asset` replaces it — or the user has
    # declared it irrelevant — record it for the consuming binary to complain
    # about. Recording rather than failing here is deliberate: the whole lock
    # is materialised, including packages nothing depends on.
    unreplaced_hook = ""
    if not ctx.attr.code_assets and not ctx.attr.ignore_hook:
        for candidate in ["hook/build.dart", "hook/link.dart"]:
            if ctx.path(candidate).exists:
                unreplaced_hook = candidate
                break

    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = language_version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        version = ctx.attr.version,
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
