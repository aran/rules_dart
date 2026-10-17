"""Repository rule that downloads a single package from a pubspec.lock.

Each hosted package gets its own external repository (spoke), with the hub
repo providing aliases for backward-compatible `@hub//:pkg` labels.

Also re-exports `make_dart_library_build_content` as a public Starlark
helper. Other Bazel rule sets (notably rules_flutter's `flutter_pub_package`,
the `flutter pub get` analog) reuse this helper to emit the same
`dart_library` shape for non-plugin packages without duplicating the format.
"""

load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _make_dart_library_build_content = "make_dart_library_build_content")
load("//dart/pub/private:language_version.bzl", _derive_language_version = "derive_language_version")

# Re-export for consumers outside //dart/pub (rules_flutter's
# flutter_pub_package). Loading the private bzl directly would trip
# buildifier's bzl-visibility check, so we expose it via this public file.
derive_language_version = _derive_language_version
make_dart_library_build_content = _make_dart_library_build_content

def pub_lock_package_sha256_error(package_name, version, sha256):
    """Returns an error string when `sha256` is empty, or None."""
    if not sha256:
        return 'pub_lock_package "%s" (%s) requires a non-empty sha256.' % (
            package_name,
            version,
        )
    return None

def trim_gzip_trailing_nulls(data):
    """Strips trailing NUL padding after a `.tar.gz` gzip stream.

    Some pub.dev tarballs (e.g. `nested@1.0.0`) are padded with NUL bytes to a
    10 KiB tar record boundary past the 8-byte RFC 1952 gzip trailer (4-byte
    CRC32 + 4-byte little-endian uncompressed `ISIZE`). Bazel's
    `GzipCompressorInputStream` rejects trailing bytes after the trailer with
    `Garbage after a valid .gz stream`.

    Because the uncompressed stream is a `.tar` archive (a non-empty multiple
    of 512 bytes), `ISIZE % 512 == 0`, so `ISIZE[0] == 0` and at least one of
    `ISIZE[1..3]` is non-zero (for archives < 4 GiB), meaning an unpadded
    `.tar.gz` ends with at most two NUL bytes.

    Args:
        data: Raw archive bytes as an ISO-8859-1 Starlark string.

    Returns:
        The archive bytes with any trailing NUL padding past the gzip trailer
        removed.
    """
    if not data.endswith("\0\0\0\0"):
        return data
    stripped = data.rstrip("\0")
    if len(stripped) < 10:
        return data
    b2_zero = stripped[-2:-1] == "\0"
    b3_zero = stripped[-3:-2] == "\0"
    if b2_zero and not b3_zero:
        return stripped + "\0\0"
    if b3_zero and not b2_zero:
        if stripped[-4:-3] == "\0" and (hash(stripped[-2:-1]) + hash(stripped[-1:]) * 256) * 256 < len(stripped):
            return stripped
        return stripped + "\0"
    if b2_zero and b3_zero:
        b = hash(stripped[-1:])
        if b % 2 != 0 or b * 256 < len(stripped):
            return stripped + "\0"
        return stripped + "\0\0"
    return stripped

def _pub_lock_package_impl(ctx):
    err = pub_lock_package_sha256_error(
        ctx.attr.package_name,
        ctx.attr.version,
        ctx.attr.sha256,
    )
    if err:
        fail(err)

    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = ctx.attr.base_url,
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )

    # pub.dev serves some tarballs padded with trailing NUL bytes past the
    # 8-byte RFC 1952 gzip trailer (observed as of 2026-04 on `nested@1.0.0`,
    # among others). Bazel's built-in `GzipCompressorInputStream` rejects
    # trailing bytes after the trailer with `Garbage after a valid .gz stream`.
    #
    # Download the archive (verifying its sha256), strip any trailing NUL
    # padding past the gzip trailer, and unpack with `ctx.extract`.
    ctx.download(
        url = url,
        output = "_archive.tar.gz",
        sha256 = ctx.attr.sha256,
    )
    raw_archive = ctx.read("_archive.tar.gz", watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete("_archive.tar.gz")
        ctx.file("_archive.tar.gz", trimmed_archive, executable = False)
    ctx.extract("_archive.tar.gz")
    ctx.delete("_archive.tar.gz")

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

    # Build full label strings for sibling repos: a dependency declared with
    # `pub.package()` is that explicit repo, every other one is its spoke.
    explicit = {p: True for p in ctx.attr.explicit_packages}
    dep_labels = [
        "@{repo}//:{dep}".format(
            repo = dep if dep in explicit else "{hub}__{dep}".format(hub = ctx.attr.hub_name, dep = dep),
            dep = dep,
        )
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
        "explicit_packages": attr.string_list(
            doc = "Every name declared with `pub.package()`. A dependency on one of these " +
                  "points at that explicit repository, not a spoke, and is kept even when " +
                  "no lock file lists it.",
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
