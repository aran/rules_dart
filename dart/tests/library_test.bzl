"""Unit tests for dart_library.bzl helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:dart_library.bzl", "check_files_under_lib_root", "check_no_duplicate_srcs")

def _stray_src_rejected_test_impl(ctx):
    # The helper is unit-tested below; this asserts `dart_library` actually
    # calls it. Without a case at the rule level, deleting the `fail()` would
    # leave every unit test passing.
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is not under")
    return analysistest.end(env)

stray_src_rejected_test = analysistest.make(
    _stray_src_rejected_test_impl,
    expect_failure = True,
)

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

def _lib_root_accepts_lib_sources_test_impl(ctx):
    env = unittest.begin(ctx)
    err = check_files_under_lib_root(
        "//pkg:lib",
        "pkg",
        [
            _fake_file("pkg/lib/user.dart", "pkg/lib/user.dart"),
            _fake_file("pkg/lib/src/deep.dart", "pkg/lib/src/deep.dart"),
        ],
    )
    asserts.equals(env, None, err)
    return unittest.end(env)

def _lib_root_accepts_root_package_test_impl(ctx):
    # A root package has an empty lib_root; its sources sit at `lib/` directly.
    # Every e2e workspace's `//:rootlib` is this shape.
    env = unittest.begin(ctx)
    err = check_files_under_lib_root("//:lib", "", [_fake_file("lib/a.dart", "lib/a.dart")])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _lib_root_accepts_external_repo_test_impl(ctx):
    # pub spokes: `derive_lib_root` yields `../<repo>` to match short_path.
    env = unittest.begin(ctx)
    err = check_files_under_lib_root(
        "@dart_pub__path//:path",
        "../+pub+dart_pub__path",
        [_fake_file("x", "../+pub+dart_pub__path/lib/path.dart")],
    )
    asserts.equals(env, None, err)
    return unittest.end(env)

def _lib_root_rejects_source_outside_lib_test_impl(ctx):
    # The reported case: a file beside `lib/` rather than inside it. Staging
    # strips lib_root, so it lands outside `lib/` and no `package:` URI reaches
    # it — previously surfacing only as a missing path at kernel-compile time.
    env = unittest.begin(ctx)
    err = check_files_under_lib_root(
        "//pkg:lib",
        "pkg",
        [_fake_file("pkg/config.g.dart", "pkg/config.g.dart")],
    )
    asserts.true(env, err != None, "expected a lib/ error, got None")
    asserts.true(env, "pkg/config.g.dart" in err, "should name the file: %s" % err)
    asserts.true(env, "pkg/lib/" in err, "should name the expected prefix: %s" % err)
    return unittest.end(env)

def _lib_root_rejects_foreign_codegen_output_test_impl(ctx):
    # A codegen target outside the Dart package root declares outputs relative
    # to its own package, so the path keeps that prefix and never resolves.
    env = unittest.begin(ctx)
    err = check_files_under_lib_root(
        "//pkg:lib",
        "pkg",
        [_fake_file("x", "pkg/gen/pkg/lib/item.g.dart")],
    )
    asserts.true(env, err != None, "expected a lib/ error for a foreign codegen output")
    asserts.true(env, "codegen" in err, "should hint at the codegen case: %s" % err)
    return unittest.end(env)

_clean_srcs_test = unittest.make(_clean_srcs_no_error_test_impl)
_lib_root_ok_test = unittest.make(_lib_root_accepts_lib_sources_test_impl)
_lib_root_root_pkg_test = unittest.make(_lib_root_accepts_root_package_test_impl)
_lib_root_external_test = unittest.make(_lib_root_accepts_external_repo_test_impl)
_lib_root_outside_test = unittest.make(_lib_root_rejects_source_outside_lib_test_impl)
_lib_root_codegen_test = unittest.make(_lib_root_rejects_foreign_codegen_output_test_impl)
_identical_file_test = unittest.make(_identical_file_listed_twice_no_error_test_impl)
_collision_test = unittest.make(_source_tree_vs_declared_output_collision_test_impl)

def library_test_suite(name):
    """Declares the `dart_library.bzl` helper unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """

    # Instantiate each test with its own name so failures identify the
    # behaviour, not a positional index (`unittest.suite`'s default naming).
    _clean_srcs_test(name = "library_clean_srcs_test", size = "small")
    _identical_file_test(name = "library_identical_file_test", size = "small")
    _collision_test(name = "library_collision_test", size = "small")
    _lib_root_ok_test(name = "library_lib_root_ok_test", size = "small")
    _lib_root_root_pkg_test(name = "library_lib_root_root_pkg_test", size = "small")
    _lib_root_external_test(name = "library_lib_root_external_test", size = "small")
    _lib_root_outside_test(name = "library_lib_root_outside_test", size = "small")
    _lib_root_codegen_test(name = "library_lib_root_codegen_test", size = "small")
    native.test_suite(
        name = name,
        tests = [
            ":library_clean_srcs_test",
            ":library_identical_file_test",
            ":library_collision_test",
            ":library_lib_root_ok_test",
            ":library_lib_root_root_pkg_test",
            ":library_lib_root_external_test",
            ":library_lib_root_outside_test",
            ":library_lib_root_codegen_test",
        ],
    )
