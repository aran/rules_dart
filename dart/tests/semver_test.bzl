"""Unit tests for the semver helpers in dart/pub/private/version.bzl.

Covers build-metadata (`+N`) parsing, release-version ordering, and the
previously-problematic stable-vs-prerelease cross comparison (which used
to type-mismatch at runtime).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:version.bzl", "parse_semver", "semver_gt")
load(":small_suite.bzl", "small_unittest_suite")

def _basic_ordering_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, semver_gt("2.0.0", "1.0.0"), "major bump")
    asserts.true(env, semver_gt("1.1.0", "1.0.0"), "minor bump")
    asserts.true(env, semver_gt("1.0.1", "1.0.0"), "patch bump")
    asserts.false(env, semver_gt("1.0.0", "1.0.0"), "equal")
    asserts.false(env, semver_gt("1.0.0", "2.0.0"), "lower lt higher")
    return unittest.end(env)

def _build_metadata_parses_test_impl(ctx):
    env = unittest.begin(ctx)

    # Build-metadata stripping, previously crashed on +N suffix.
    asserts.equals(env, parse_semver("2.7.1+4"), parse_semver("2.7.1"), "+4 stripped")
    asserts.equals(env, parse_semver("2.7.1+meta.42"), parse_semver("2.7.1"), "+meta.42 stripped")
    return unittest.end(env)

def _build_metadata_ordering_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, semver_gt("2.7.2", "2.7.1+4"), "next patch beats version with build metadata")
    asserts.false(env, semver_gt("2.7.1+5", "2.7.1+4"), "build metadata does not affect precedence")
    asserts.false(env, semver_gt("2.7.1+4", "2.7.1"), "build metadata not greater than no-metadata")
    return unittest.end(env)

def _stable_vs_prerelease_test_impl(ctx):
    env = unittest.begin(ctx)

    # Stable wins over any prerelease of the same release number. Previously
    # this comparison crashed with a type mismatch; the unified 5-tuple
    # shape makes it work cleanly.
    asserts.true(env, semver_gt("1.0.0", "1.0.0-dev.1"), "stable > prerelease")
    asserts.false(env, semver_gt("1.0.0-dev.1", "1.0.0"), "prerelease < stable")
    asserts.true(env, semver_gt("1.0.0-rc.2", "1.0.0-rc.1"), "rc.2 > rc.1")
    asserts.true(env, semver_gt("1.0.0-alpha.2", "1.0.0-alpha.1"), "numeric prerelease segments")
    asserts.true(env, semver_gt("1.0.0-beta", "1.0.0-alpha"), "identifier prerelease segments")

    # Numeric prerelease segments sort before identifier segments (per
    # semver §11.4.3).
    asserts.true(env, semver_gt("1.0.0-alpha", "1.0.0-1"), "identifier > numeric segment")

    # Different patches: build metadata / prerelease tags must not override
    # the release triple.
    asserts.true(env, semver_gt("2.0.0-dev.1", "1.99.99"), "major prerelease beats lower stable major")
    return unittest.end(env)

_t0_test = unittest.make(_basic_ordering_test_impl)
_t1_test = unittest.make(_build_metadata_parses_test_impl)
_t2_test = unittest.make(_build_metadata_ordering_test_impl)
_t3_test = unittest.make(_stable_vs_prerelease_test_impl)

def semver_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
