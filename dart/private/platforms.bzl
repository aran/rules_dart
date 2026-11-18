"""The hosts a Dart SDK runs on. Repository rules holding fetched files load this, so keep it small."""

visibility("//dart/...")

# HOST platforms: those we download an SDK for and can run a build on. Each key
# is both the download-URL slug and the `versions.bzl` checksum key:
# https://storage.googleapis.com/dart-archive/channels/stable/release/{version}/sdk/dartsdk-{platform}-release.zip
# Every entry costs one SHA-256 per pinned version, so add one only for a
# platform Bazel itself ships a release for. Cross-compilation destinations go
# in `TARGET_ONLY_PLATFORMS` instead.
PLATFORMS = {
    "macos-arm64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        dart_os = "macos",
        dart_arch = "arm64",
    ),
    "macos-x64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        dart_os = "macos",
        dart_arch = "x64",
    ),
    "linux-x64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        dart_os = "linux",
        dart_arch = "x64",
    ),
    "linux-arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        dart_os = "linux",
        dart_arch = "arm64",
    ),
    "windows-x64": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        dart_os = "windows",
        dart_arch = "x64",
    ),
}

def host_platform(os):
    """The `PLATFORMS` key of the host a repository rule runs on.

    Args:
        os: `repository_ctx.os`.

    Returns:
        A `PLATFORMS` key, e.g. `macos-arm64`.
    """
    name = os.name.lower()
    cpu = "arm64" if os.arch in ("aarch64", "arm64") else "x64"
    if name.startswith("mac"):
        platform = "macos-" + cpu
    elif name.startswith("windows"):
        platform = "windows-" + cpu
    else:
        platform = "linux-" + cpu
    if platform not in PLATFORMS:
        fail("The Dart SDK has no build for this host ({} {}), so rules_dart cannot run on it.".format(os.name, os.arch))
    return platform
