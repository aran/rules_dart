# BUILD file for the `package:webcrypto` pub archive, overlaid by the
# `http_archive` in rules_dart's MODULE.bazel. It compiles what the package's
# hook/build.dart compiles through src/CMakeLists.txt: the package's own C
# glue over the BoringSSL revision vendored in third_party/boringssl, with
# every symbol prefixed `webcrypto_`. The Dart bindings are generated against
# those exact headers and name the prefixed symbols, so no other BoringSSL
# would do.
#
# The vendored tree holds exactly the files sources.cmake lists, so globs
# select the same sources. Assembly is guarded per OS and architecture inside
# each file, so non-Windows builds take it all; Windows builds take none and
# define OPENSSL_NO_ASM, because Bazel's C++ rules cannot drive NASM. Both
# choices follow BoringSSL's own Bazel build.

load("@package_metadata//purl:purl.bzl", "purl")
load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_hosted_purl")

# The archive is the pub package, so its own C glue is the package's code:
# the version and digest are those of the archive MODULE.bazel pins. The
# BoringSSL it vendors is BoringSSL's, at the revision in tool/REVISION, and
# is identified as that instead.
package(default_package_metadata = [":package_metadata"])

package_metadata(
    name = "package_metadata",
    purl = pub_hosted_purl(
        "webcrypto",
        "0.6.2",
        "bdfa2b11696f2bac02834649d9e07d24a5154e527feec21ed1bdf81b31f982df",
    ),
)

_BORINGSSL_REVISION = "5ee9407bc28dd9086507f02851886a185088f3a0"

package_metadata(
    name = "boringssl_package_metadata",
    purl = purl.builder().type("generic").name("boringssl").version(_BORINGSSL_REVISION).add_qualifier(
        "vcs_url",
        "git+https://boringssl.googlesource.com/boringssl@" + _BORINGSSL_REVISION,
    ).build(),
)

_BORINGSSL = "third_party/boringssl/"

# BORINGSSL_SHARED_LIBRARY and BORINGSSL_IMPLEMENTATION make OPENSSL_EXPORT
# export BoringSSL's public API, which Dart calls, from the shared library.
_COPTS = [
    "-DOPENSSL_SMALL",
    "-DBORINGSSL_PREFIX=webcrypto",
    "-DBORINGSSL_SHARED_LIBRARY",
    "-DBORINGSSL_IMPLEMENTATION",
] + select({
    "@platforms//os:windows": [
        "-DOPENSSL_NO_ASM",
        "-DWIN32_LEAN_AND_MEAN",
        "-DNOMINMAX",
        "-D_HAS_EXCEPTIONS=0",
        "-D_CRT_SECURE_NO_WARNINGS",
        "-utf-8",
    ],
    # Only what is marked for export is visible: BoringSSL's public API and
    # webcrypto_get_CBB_size, which Dart calls by name.
    "//conditions:default": ["-fvisibility=hidden"],
}) + select({
    # glibc hides pthread rwlocks without this; it must not be set on Apple.
    "@platforms//os:linux": ["-D_XOPEN_SOURCE=700"],
    "//conditions:default": [],
})

cc_library(
    name = "boringssl_crypto",
    srcs = glob([
        _BORINGSSL + "**/*.cc",
        _BORINGSSL + "**/*.h",
        _BORINGSSL + "**/*.inc",
    ]) + select({
        "@platforms//os:windows": [],
        "//conditions:default": glob([_BORINGSSL + "**/*.S"]),
    }),
    copts = _COPTS,
    cxxopts = select({
        "@platforms//os:windows": ["/std:c++17"],
        "//conditions:default": ["-std=c++17"],
    }),
    includes = [_BORINGSSL + "src/include"],
    linkopts = select({
        "@platforms//os:windows": [
            "-defaultlib:advapi32.lib",
            "-defaultlib:ws2_32.lib",
        ],
        "//conditions:default": ["-pthread"],
    }),
    package_metadata = [":boringssl_package_metadata"],
    # Dart calls BoringSSL directly and nothing in the shared library calls
    # most of it, so keep every object file at link time, as the hook does.
    alwayslink = True,
)

cc_library(
    name = "webcrypto",
    srcs = [
        "src/webcrypto.c",
        "src/webcrypto.h",
    ],
    copts = _COPTS,
    visibility = ["@rules_dart//dart/ext/webcrypto:__pkg__"],
    deps = [":boringssl_crypto"],
    # Nothing in the shared library references webcrypto_get_CBB_size, so keep
    # its object file from being dropped at link time.
    alwayslink = True,
)
