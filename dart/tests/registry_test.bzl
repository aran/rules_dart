"""Unit tests for the curated code-asset registry."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/ext:registry.bzl", "curated_code_assets", "curated_packages")
load(":small_suite.bzl", "small_unittest_suite")

def _known_package_in_range_test_impl(ctx):
    env = unittest.begin(ctx)
    labels = curated_code_assets("sqlite3", "2.9.0")
    asserts.equals(env, ["@rules_dart//dart/ext/sqlite3:code_asset"], labels)
    return unittest.end(env)

def _known_package_below_range_test_impl(ctx):
    # An asset id is a path inside a particular version of a package. Below the
    # bound, `//dart/ext/sqlite3`'s id may not be where the bindings live, so
    # attaching it would be silently wrong — better to attach nothing and let
    # the unreplaced-hook diagnostic fire.
    env = unittest.begin(ctx)
    asserts.equals(env, [], curated_code_assets("sqlite3", "1.11.2"))
    return unittest.end(env)

def _unknown_package_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], curated_code_assets("some_other_package", "1.0.0"))
    return unittest.end(env)

def _prerelease_in_range_test_impl(ctx):
    # `2.0.0-dev.1` sorts below `2.0.0` per semver, so an inclusive lower bound
    # of 2.0.0 must exclude it rather than accidentally admitting it.
    env = unittest.begin(ctx)
    asserts.equals(env, [], curated_code_assets("sqlite3", "2.0.0-dev.1"))
    asserts.equals(env, ["@rules_dart//dart/ext/sqlite3:code_asset"], curated_code_assets("sqlite3", "2.0.0"))
    return unittest.end(env)

def _curated_packages_test_impl(ctx):
    # Sorted order is part of the contract: rules_flutter renders this list
    # into its own "packages with a replacement" diagnostic, and an unstable
    # order would make that text differ between the two rule sets.
    env = unittest.begin(ctx)
    packages = curated_packages()
    asserts.true(env, "sqlite3" in packages)
    asserts.equals(env, sorted(packages), packages)
    return unittest.end(env)

def _labels_resolve_from_foreign_repo_test_impl(ctx):
    # The resolver is loaded by other rule sets, which paste these labels into
    # BUILD content they generate in their own repositories. A bare `//…` label
    # would resolve against *their* repo and break; only an apparent-repo
    # qualified label survives the trip.
    env = unittest.begin(ctx)
    for label in curated_code_assets("sqlite3", "2.9.0"):
        asserts.equals(env, "string", type(label))
        asserts.true(
            env,
            label.startswith("@rules_dart//"),
            "curated label %r must be repo-qualified to resolve downstream" % label,
        )
    return unittest.end(env)

_t0_test = unittest.make(_known_package_in_range_test_impl)
_t1_test = unittest.make(_known_package_below_range_test_impl)
_t2_test = unittest.make(_unknown_package_test_impl)
_t3_test = unittest.make(_prerelease_in_range_test_impl)
_t4_test = unittest.make(_curated_packages_test_impl)
_t5_test = unittest.make(_labels_resolve_from_foreign_repo_test_impl)

def registry_test_suite(name):
    """Declares the curated-registry unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
