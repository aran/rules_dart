"""Unit tests for dart_library.bzl helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_library.bzl", "check_no_duplicate_srcs")

def _fake_file(path, short_path):
    """Fake File struct — enough surface for `check_no_duplicate_srcs`."""
    return struct(path = path, short_path = short_path)

def _clean_srcs_no_error_test_impl(ctx):
    env = unittest.begin(ctx)
    err = check_no_duplicate_srcs(
        "//pkg:lib",
        [
            _fake_file("pkg/lib/user.dart", "pkg/lib/user.dart"),
            _fake_file("pkg/lib/helper.dart", "pkg/lib/helper.dart"),
        ],
    )
    asserts.equals(env, None, err)
    return unittest.end(env)

def _identical_file_listed_twice_no_error_test_impl(ctx):
    # label_list deduplication handles this in practice, but the helper
    # should also tolerate it — same path and same short_path is not a
    # collision.
    env = unittest.begin(ctx)
    f = _fake_file("pkg/lib/user.dart", "pkg/lib/user.dart")
    err = check_no_duplicate_srcs("//pkg:lib", [f, f])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _source_tree_vs_declared_output_collision_test_impl(ctx):
    env = unittest.begin(ctx)
    err = check_no_duplicate_srcs(
        "//pkg:lib",
        [
            _fake_file("pkg/lib/user.dart", "pkg/lib/user.dart"),
            _fake_file("pkg/lib/user.g.dart", "pkg/lib/user.g.dart"),
            _fake_file(
                "bazel-out/darwin-fastbuild/bin/pkg/lib/user.g.dart",
                "pkg/lib/user.g.dart",
            ),
        ],
    )
    asserts.true(env, err != None, "expected a collision error, got None")
    asserts.true(
        env,
        "pkg/lib/user.g.dart" in err,
        "expected the colliding path in the error: %s" % err,
    )
    asserts.true(
        env,
        "stale" in err,
        "expected the diagnostic to mention staleness: %s" % err,
    )
    asserts.true(
        env,
        "bazel-out" in err,
        "expected both on-disk paths in the error: %s" % err,
    )
    return unittest.end(env)

_clean_srcs_test = unittest.make(_clean_srcs_no_error_test_impl)
_identical_file_test = unittest.make(_identical_file_listed_twice_no_error_test_impl)
_collision_test = unittest.make(_source_tree_vs_declared_output_collision_test_impl)

def library_test_suite(name):
    # Instantiate each test with its own name so failures identify the
    # behaviour, not a positional index (`unittest.suite`'s default naming).
    _clean_srcs_test(name = "library_clean_srcs_test")
    _identical_file_test(name = "library_identical_file_test")
    _collision_test(name = "library_collision_test")
    native.test_suite(
        name = name,
        tests = [
            ":library_clean_srcs_test",
            ":library_identical_file_test",
            ":library_collision_test",
        ],
    )
