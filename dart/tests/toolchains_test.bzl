"""Unit tests for the platform tables that drive toolchain generation.

`toolchains_repo.bzl` generates `@dart_toolchains//:BUILD.bazel` from three
tables, and nothing else validates them. A bad entry surfaces as a raw Starlark
`KeyError` during repository evaluation, or — worse — as a toolchain that
silently never matches. These assert the invariants the generator depends on.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/private:toolchains_repo.bzl",
    "CROSS_TARGETS",
    "PLATFORMS",
    "TARGET_ONLY_PLATFORMS",
    "TARGET_PLATFORMS",
)
load("//dart/private:versions.bzl", "TOOL_VERSIONS")
load(":small_suite.bzl", "small_unittest_suite")

# Dart's `--target-arch` vocabulary (`dart compile exe --help`).
_DART_ARCHES = ["arm", "arm64", "ia32", "riscv32", "riscv64", "x64"]

# Dart's `--target-os` vocabulary, restricted to those we generate toolchains
# for. Dart also accepts android/fuchsia/ios, which rules_dart does not target.
_DART_OSES = ["linux", "macos", "windows"]

def _target_platforms_is_the_union_test_impl(ctx):
    env = unittest.begin(ctx)

    # PLATFORMS and TARGET_ONLY_PLATFORMS must be disjoint: an entry in both
    # would mean one Dart arch owning two `dart_toolchain_cross_*` names.
    for key in TARGET_ONLY_PLATFORMS.keys():
        asserts.false(
            env,
            key in PLATFORMS,
            "%s is in both PLATFORMS and TARGET_ONLY_PLATFORMS" % key,
        )

    asserts.equals(
        env,
        len(PLATFORMS) + len(TARGET_ONLY_PLATFORMS),
        len(TARGET_PLATFORMS),
        "TARGET_PLATFORMS must be exactly the union of the two tables",
    )
    for key in PLATFORMS.keys() + TARGET_ONLY_PLATFORMS.keys():
        asserts.true(env, key in TARGET_PLATFORMS, "%s missing from TARGET_PLATFORMS" % key)

    return unittest.end(env)

def _cross_targets_resolve_test_impl(ctx):
    env = unittest.begin(ctx)

    for exec_platform, targets in CROSS_TARGETS.items():
        # An exec platform runs the compiler, so it needs its own SDK.
        asserts.true(
            env,
            exec_platform in PLATFORMS,
            "CROSS_TARGETS key %s is not a host platform" % exec_platform,
        )
        for target in targets:
            # This is the exact lookup `_toolchains_repo_impl` performs; a miss
            # is a KeyError during repo evaluation.
            asserts.true(
                env,
                target in TARGET_PLATFORMS,
                "CROSS_TARGETS[%s] names unknown target %s" % (exec_platform, target),
            )

            # A self-pair would emit a cross toolchain whose exec and target
            # constraints both equal the native one's. The native toolchain is
            # written first and would win, leaving the cross entry dead.
            asserts.false(
                env,
                target == exec_platform,
                "CROSS_TARGETS[%s] contains itself" % exec_platform,
            )

        # Duplicate targets would emit two toolchains with the same name.
        asserts.equals(
            env,
            len(targets),
            len({t: None for t in targets}),
            "CROSS_TARGETS[%s] has duplicates" % exec_platform,
        )

    return unittest.end(env)

def _platform_metadata_shape_test_impl(ctx):
    env = unittest.begin(ctx)

    for name, meta in TARGET_PLATFORMS.items():
        oses = [c for c in meta.compatible_with if c.startswith("@platforms//os:")]
        cpus = [c for c in meta.compatible_with if c.startswith("@platforms//cpu:")]
        asserts.equals(env, 1, len(oses), "%s needs exactly one os constraint" % name)
        asserts.equals(env, 1, len(cpus), "%s needs exactly one cpu constraint" % name)
        asserts.equals(
            env,
            len(meta.compatible_with),
            len(oses) + len(cpus),
            "%s has a constraint that is neither os nor cpu" % name,
        )

        # dart_os/dart_arch are passed straight to `--target-os`/`--target-arch`,
        # so a typo becomes a compiler error in a cross build we may not test.
        asserts.true(
            env,
            meta.dart_os in _DART_OSES,
            "%s: dart_os %r is not a Dart target OS" % (name, meta.dart_os),
        )
        asserts.true(
            env,
            meta.dart_arch in _DART_ARCHES,
            "%s: dart_arch %r is not a Dart target arch" % (name, meta.dart_arch),
        )

    return unittest.end(env)

def _checksums_cover_every_host_test_impl(ctx):
    env = unittest.begin(ctx)

    # `_dart_sdk_repo_impl` does TOOL_VERSIONS[version][platform], which hard
    # errors on a miss. Every pinned version therefore needs every host key —
    # and no extras, which would mean a checksum for a platform we never fetch.
    want = sorted(PLATFORMS.keys())
    for version, checksums in TOOL_VERSIONS.items():
        asserts.equals(
            env,
            want,
            sorted(checksums.keys()),
            "TOOL_VERSIONS[%s] does not match the host platform set" % version,
        )

    # Cross-only targets must NOT carry checksums: no SDK is downloaded for them.
    for version, checksums in TOOL_VERSIONS.items():
        for key in TARGET_ONLY_PLATFORMS.keys():
            asserts.false(
                env,
                key in checksums,
                "TOOL_VERSIONS[%s] has a checksum for cross-only %s" % (version, key),
            )

    return unittest.end(env)

_t0_test = unittest.make(_target_platforms_is_the_union_test_impl)
_t1_test = unittest.make(_cross_targets_resolve_test_impl)
_t2_test = unittest.make(_platform_metadata_shape_test_impl)
_t3_test = unittest.make(_checksums_cover_every_host_test_impl)

def toolchains_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
