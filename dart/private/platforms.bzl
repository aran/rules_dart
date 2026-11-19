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
    "windows-arm64": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
        dart_os = "windows",
        dart_arch = "arm64",
    ),
}

_HOST_OS = {"mac": "macos", "windows": "windows", "linux": "linux"}

_HOST_CPU = {
    "aarch64": "arm64",
    "arm64": "arm64",
    "amd64": "x64",
    "x64": "x64",
    "x86_64": "x64",
}

def host_platform(os):
    """The `PLATFORMS` key of the host a repository rule runs on, if it has one.

    A host with none is not an error here: a repository must still fetch on it,
    for `bazel fetch --all` and `bazel vendor`, and what needs an SDK says so
    with `unsupported_host_message` when it is used.

    Args:
        os: `repository_ctx.os`.

    Returns:
        A `PLATFORMS` key, e.g. `macos-arm64`, or None for a host the Dart SDK
        has no build for.
    """
    name = os.name.lower()
    cpu = _HOST_CPU.get(os.arch.lower())
    for prefix, dart_os in _HOST_OS.items():
        if name.startswith(prefix) and cpu:
            platform = dart_os + "-" + cpu
            return platform if platform in PLATFORMS else None
    return None

def unsupported_host_message(os):
    """What to say on a host `host_platform` has no key for.

    Args:
        os: `repository_ctx.os`.

    Returns:
        The message.
    """
    return "rules_dart has no Dart SDK for this machine ({} {}). It runs on: {}.".format(
        os.name,
        os.arch,
        ", ".join(sorted(PLATFORMS.keys())),
    )
