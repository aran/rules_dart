"""Unit tests for dart_library.bzl helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:common.bzl", "derive_package_name")
load("//dart/private:dart_library.bzl", "check_files_under_package_root", "check_no_duplicate_srcs")
load("//dart/private:package_root.bzl", "locate_package_root")

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

def _nested_lib_rejected_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "named `lib` inside another `lib/`")
    return analysistest.end(env)

nested_lib_rejected_test = analysistest.make(
    _nested_lib_rejected_test_impl,
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

def _package_root_accepts_lib_sources_test_impl(ctx):
    env = unittest.begin(ctx)
    err = check_files_under_package_root(
        "//pkg:lib",
        "pkg",
        [
            _fake_file("pkg/lib/user.dart", "pkg/lib/user.dart"),
            _fake_file("pkg/lib/src/deep.dart", "pkg/lib/src/deep.dart"),
        ],
    )
    asserts.equals(env, None, err)
    return unittest.end(env)

def _package_root_accepts_root_package_test_impl(ctx):
    # A root package has an empty package_root; its sources sit at `lib/` directly.
    # Every e2e workspace's `//:rootlib` is this shape.
    env = unittest.begin(ctx)
    err = check_files_under_package_root("//:lib", "", [_fake_file("lib/a.dart", "lib/a.dart")])
    asserts.equals(env, None, err)
    return unittest.end(env)

def _package_root_accepts_external_repo_test_impl(ctx):
    # pub spokes: `derive_package_root` yields `../<repo>` to match short_path.
    env = unittest.begin(ctx)
    err = check_files_under_package_root(
        "@dart_pub__path//:path",
        "../+pub+dart_pub__path",
        [_fake_file("x", "../+pub+dart_pub__path/lib/path.dart")],
    )
    asserts.equals(env, None, err)
    return unittest.end(env)

def _package_root_rejects_source_outside_lib_test_impl(ctx):
    # A file beside `lib/` rather than inside it. Staging strips package_root, so
    # it lands outside `lib/` and no `package:` URI reaches it; unchecked, it
    # would surface only as a missing path at kernel-compile time.
    env = unittest.begin(ctx)
    err = check_files_under_package_root(
        "//pkg:lib",
        "pkg",
        [_fake_file("pkg/config.g.dart", "pkg/config.g.dart")],
    )
    asserts.true(env, err != None, "expected a lib/ error, got None")
    asserts.true(env, "pkg/config.g.dart" in err, "should name the file: %s" % err)
    asserts.true(env, "pkg/lib/" in err, "should name the expected prefix: %s" % err)
    return unittest.end(env)

def _package_root_rejects_foreign_codegen_output_test_impl(ctx):
    # A codegen target outside the Dart package root declares outputs relative
    # to its own package, so the path keeps that prefix and never resolves.
    env = unittest.begin(ctx)
    err = check_files_under_package_root(
        "//pkg:lib",
        "pkg",
        [_fake_file("x", "pkg/gen/pkg/lib/item.g.dart")],
    )
    asserts.true(env, err != None, "expected a lib/ error for a foreign codegen output")
    asserts.true(env, "codegen" in err, "should hint at the codegen case: %s" % err)
    return unittest.end(env)

def _root_of(workspace_root, label_package, files = []):
    return locate_package_root(workspace_root, label_package, [_fake_file(f, f) for f in files])

def _package_root_from_path_test_impl(ctx):
    env = unittest.begin(ctx)

    # At the package root, and in its `lib/`: as before subdirectories counted.
    asserts.equals(env, struct(root = "pkg", error = None), _root_of("", "pkg", ["pkg/lib/a.dart"]))
    asserts.equals(env, struct(root = "pkg", error = None), _root_of("", "pkg/lib", ["pkg/lib/a.dart"]))
    asserts.equals(env, struct(root = "", error = None), _root_of("", "lib"))
    asserts.equals(env, struct(root = "", error = None), _root_of("", ""))

    # In a directory under `lib/`: the directory above that `lib`.
    asserts.equals(env, struct(root = "pkg", error = None), _root_of("", "pkg/lib/src/model", ["pkg/lib/src/model/m.dart"]))
    asserts.equals(env, struct(root = "", error = None), _root_of("", "lib/src/model"))

    # External repositories, whose directory name is never read for `lib`.
    asserts.equals(env, struct(root = "../lib", error = None), _root_of("external/lib", ""))
    asserts.equals(env, struct(root = "../r/pkg", error = None), _root_of("external/r", "pkg/lib/src"))
    return unittest.end(env)

def _package_root_ambiguous_test_impl(ctx):
    env = unittest.begin(ctx)

    # Two `lib` components in the BUILD file's own path.
    err = _root_of("", "pkg/lib/src/lib").error
    asserts.true(env, err != None and "//pkg/lib/src/lib" in err, "got %s" % err)

    # One, with files under the target's own `lib/`: the package may be rooted
    # there or above the outer `lib`.
    err = _root_of("", "x/lib/y", ["x/lib/y/lib/a.dart"]).error
    asserts.true(env, err != None and "x/lib/y/lib/a.dart" in err and "`//x`" in err, "got %s" % err)
    err = _root_of("external/r", "x/lib/y", ["../r/x/lib/y/lib/a.dart"]).error
    asserts.true(env, err != None, "expected an error in an external repository")
    return unittest.end(env)

def _package_name_from_root_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "pkg", derive_package_name("", "a/pkg", "t"))
    asserts.equals(env, "pkg", derive_package_name("", "a/pkg/lib", "t"))
    asserts.equals(env, "pkg", derive_package_name("", "a/pkg/lib/src/model", "t"))
    asserts.equals(env, "t", derive_package_name("", "lib/src/model", "t"))
    asserts.equals(env, "t", derive_package_name("", "", "t"))
    asserts.equals(env, "named", derive_package_name("named", "a/pkg/lib/src", "t"))
    return unittest.end(env)

_package_root_from_path_test = unittest.make(_package_root_from_path_test_impl)
_package_root_ambiguous_test = unittest.make(_package_root_ambiguous_test_impl)
_package_name_from_root_test = unittest.make(_package_name_from_root_test_impl)

_clean_srcs_test = unittest.make(_clean_srcs_no_error_test_impl)
_package_root_ok_test = unittest.make(_package_root_accepts_lib_sources_test_impl)
_package_root_root_pkg_test = unittest.make(_package_root_accepts_root_package_test_impl)
_package_root_external_test = unittest.make(_package_root_accepts_external_repo_test_impl)
_package_root_outside_test = unittest.make(_package_root_rejects_source_outside_lib_test_impl)
_package_root_codegen_test = unittest.make(_package_root_rejects_foreign_codegen_output_test_impl)
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
    _package_root_ok_test(name = "library_package_root_ok_test", size = "small")
    _package_root_root_pkg_test(name = "library_package_root_root_pkg_test", size = "small")
    _package_root_external_test(name = "library_package_root_external_test", size = "small")
    _package_root_outside_test(name = "library_package_root_outside_test", size = "small")
    _package_root_codegen_test(name = "library_package_root_codegen_test", size = "small")
    _package_root_from_path_test(name = "library_package_root_from_path_test", size = "small")
    _package_root_ambiguous_test(name = "library_package_root_ambiguous_test", size = "small")
    _package_name_from_root_test(name = "library_package_name_from_root_test", size = "small")
    native.test_suite(
        name = name,
        tests = [
            ":library_clean_srcs_test",
            ":library_identical_file_test",
            ":library_collision_test",
            ":library_package_root_ok_test",
            ":library_package_root_root_pkg_test",
            ":library_package_root_external_test",
            ":library_package_root_outside_test",
            ":library_package_root_codegen_test",
            ":library_package_root_from_path_test",
            ":library_package_root_ambiguous_test",
            ":library_package_name_from_root_test",
        ],
    )
