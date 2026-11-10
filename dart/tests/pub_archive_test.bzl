"""Unit tests for the digest shape check in dart/pub/private/pub_archive.bzl.

A pub archive is fetched only against a digest of the shape pubspec.lock
records; anything else is refused before any request.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_archive.bzl", "is_pub_sha256")
load(":small_suite.bzl", "small_unittest_suite")

_GOOD = "e1b7f9cbf0f4a1c3e3d2b5a6978c0d1e2f3a4b5c6d7e8f90123456789abcdef0"

def _accepts_lock_digests_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_pub_sha256(_GOOD), "64 lowercase hex digits")
    asserts.true(env, is_pub_sha256("0" * 64), "all zeros is still the right shape")
    return unittest.end(env)

def _refuses_other_shapes_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_pub_sha256(""), "blank")
    asserts.false(env, is_pub_sha256(_GOOD[:63]), "one digit short")
    asserts.false(env, is_pub_sha256(_GOOD + "0"), "one digit long")
    asserts.false(env, is_pub_sha256(_GOOD.upper()), "uppercase hex")
    asserts.false(env, is_pub_sha256(_GOOD[:63] + "g"), "a non-hex digit")
    asserts.false(env, is_pub_sha256(" " + _GOOD[1:]), "a space")
    asserts.false(env, is_pub_sha256("sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="), "an SRI string")
    return unittest.end(env)

_t0_test = unittest.make(_accepts_lock_digests_test_impl)
_t1_test = unittest.make(_refuses_other_shapes_test_impl)

def pub_archive_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test)
