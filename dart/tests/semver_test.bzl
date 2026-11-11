"""Unit tests for the semver helpers in dart/pub/private/version.bzl.

Covers release ordering, build metadata (`+N`), which pub_semver orders, and
the stable-vs-prerelease cross comparison.
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

def _build_metadata_orders_test_impl(ctx):
    env = unittest.begin(ctx)

    # pub_semver orders build metadata: no build string sorts first, then
    # build parts compare as pre-release parts do.
    asserts.true(env, semver_gt("2.7.1+4", "2.7.1"), "a build sorts after no build")
    asserts.true(env, semver_gt("2.7.1+5", "2.7.1+4"), "build parts compare numerically")
    asserts.true(env, semver_gt("0.8.12+20", "0.8.12+18"), "Flutter-style build numbers")
    asserts.true(env, semver_gt("2.7.1+10", "2.7.1+9"), "numeric, not textual")
    asserts.true(env, semver_gt("2.7.1+a", "2.7.1+9"), "identifier > numeric build part")
    asserts.true(env, semver_gt("2.7.1+4.1", "2.7.1+4"), "a longer build sorts after its prefix")
    asserts.true(env, semver_gt("2.7.2", "2.7.1+4"), "next patch beats any build")
    asserts.true(env, semver_gt("1.0.0", "1.0.0-dev+9"), "a pre-release with a build stays below the release")
    asserts.true(env, semver_gt("1.0.0-dev+2", "1.0.0-dev+1"), "builds order pre-releases too")
    asserts.equals(env, parse_semver("2.7.1+01"), parse_semver("2.7.1+1"), "leading zeros in a numeric part")
    return unittest.end(env)

def _hyphen_in_build_test_impl(ctx):
    env = unittest.begin(ctx)

    # The pre-release ends at `+`; a hyphen after it is part of the build.
    asserts.true(env, semver_gt("1.0.0+hotfix-2", "1.0.0"), "hyphenated build is not a pre-release")
    asserts.true(env, semver_gt("1.0.0+hotfix-2", "1.0.0-rc.1"), "hyphenated build beats a pre-release")
    asserts.true(env, semver_gt("1.0.0-a-b", "1.0.0-a"), "hyphen inside a pre-release part")
    asserts.true(env, semver_gt("1.0.0", "1.0.0-a-b+c-d"), "pre-release with hyphenated parts and build")
    return unittest.end(env)

def _stable_vs_prerelease_test_impl(ctx):
    env = unittest.begin(ctx)

    # Stable wins over any prerelease of the same release number; both parse
    # to the same 5-tuple shape, so they compare.
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
_t1_test = unittest.make(_build_metadata_orders_test_impl)
_t2_test = unittest.make(_hyphen_in_build_test_impl)
_t3_test = unittest.make(_stable_vs_prerelease_test_impl)

def semver_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
