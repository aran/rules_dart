"""Unit tests for the checks in dart/pub/private/pub_archive.bzl.

A pub archive is fetched only against a digest of the shape pubspec.lock
records; anything else is refused before any request. An archive whose entry
names reach outside the package is refused before extraction.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_archive.bzl", "is_pub_sha256", "pub_archive_sha256_error", "tar_entry_leaves_package")
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

def _sha256_error_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, pub_archive_sha256_error("path", "1.9.1", _GOOD, "pub.package()"))

    # A declaration, with no lock to re-resolve, is pointed at the registry's API.
    asserts.equals(
        env,
        ('No sha256 is pinned for pub package "path" 1.9.1 (in pub.package()), so its archive ' +
         "cannot be verified and will not be fetched. The registry gives it as `archive_sha256` " +
         "in:\n  https://pub.dev/api/packages/path/versions/1.9.1"),
        pub_archive_sha256_error("path", "1.9.1", "", "pub.package()"),
    )

    # A lock entry is fixed by re-resolving the lock.
    in_lock = pub_archive_sha256_error("path", "1.9.1", "", "//:pubspec.lock", rewrite = "bazel run @rules_dart//dart/pub -- get")
    asserts.true(env, in_lock.endswith("and pub records the digest:\n  bazel run @rules_dart//dart/pub -- get"), in_lock)

    short = pub_archive_sha256_error("path", "1.9.1", "abc", "pub.package()", base_url = "https://registry.example/")
    asserts.true(env, short.startswith('The sha256 for pub package "path" 1.9.1 (in pub.package()) is "abc", which is not a SHA-256'), short)
    asserts.true(env, "https://registry.example/api/packages/path/versions/1.9.1" in short, short)
    return unittest.end(env)

def _entries_inside_the_package_test_impl(ctx):
    env = unittest.begin(ctx)
    for entry in ["pubspec.yaml", "lib/", "lib/src/a.dart", "./lib/a.dart", "lib/..a", "lib/a..dart", "...", "lib/.../a"]:
        asserts.false(env, tar_entry_leaves_package(entry), entry)
    return unittest.end(env)

def _entries_leaving_the_package_test_impl(ctx):
    env = unittest.begin(ctx)
    for entry in ["/etc/passwd", "/", "..", "../x", "lib/../../x", "lib/..", "\\x", "lib\\..\\..\\x", "C:/x", "c:x"]:
        asserts.true(env, tar_entry_leaves_package(entry), entry)
    return unittest.end(env)

_t0_test = unittest.make(_accepts_lock_digests_test_impl)
_t1_test = unittest.make(_refuses_other_shapes_test_impl)
_t2_test = unittest.make(_entries_inside_the_package_test_impl)
_t3_test = unittest.make(_entries_leaving_the_package_test_impl)
_t4_test = unittest.make(_sha256_error_test_impl)

def pub_archive_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
