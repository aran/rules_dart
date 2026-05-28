"""Unit tests for the source-assembly helpers (`needs_source_assembly`, `package_for`)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:source_set.bzl", "assembled_package_for", "colocate_packages", "needs_source_assembly", "package_for")

def _fake_file(is_source):
    # needs_source_assembly only inspects File.is_source.
    return struct(is_source = is_source)

def _fake_src(short_path, is_source = True, is_directory = False):
    # colocate_packages inspects short_path, is_source, is_directory.
    return struct(short_path = short_path, is_source = is_source, is_directory = is_directory)

def _fake_pkg(package_name, lib_root):
    # package_for only inspects DartPackageInfo.package_name and .lib_root.
    return struct(package_name = package_name, lib_root = lib_root)

def _all_source_no_assembly_test_impl(ctx):
    # Pure source-tree files already share one directory → no assembly.
    env = unittest.begin(ctx)
    asserts.false(env, needs_source_assembly([_fake_file(True), _fake_file(True)]))
    return unittest.end(env)

def _any_generated_needs_assembly_test_impl(ctx):
    # Any generated member straddles source tree and bazel-out → assemble.
    env = unittest.begin(ctx)
    asserts.true(env, needs_source_assembly([_fake_file(True), _fake_file(False)]))
    asserts.true(env, needs_source_assembly([_fake_file(False)]))
    return unittest.end(env)

def _empty_no_assembly_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, needs_source_assembly([]))
    return unittest.end(env)

def _package_for_root_package_test_impl(ctx):
    # The root package (empty lib_root) owns `lib/...` and nothing else.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("root", "")]
    asserts.equals(env, "root", package_for("lib/a.dart", pkgs))
    asserts.equals(env, "root", package_for("lib", pkgs))
    asserts.equals(env, None, package_for("other/a.dart", pkgs))
    return unittest.end(env)

def _package_for_longest_prefix_test_impl(ctx):
    # When two lib_roots both prefix the path, the longest one wins.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("foo", "foo"), _fake_pkg("foobar", "foo/bar")]
    asserts.equals(env, "foobar", package_for("foo/bar/lib/x.dart", pkgs))
    asserts.equals(env, "foo", package_for("foo/lib/x.dart", pkgs))
    return unittest.end(env)

def _package_for_exact_dir_test_impl(ctx):
    # An assembled package directory (short_path == lib_root) matches exactly.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("p", "pkg/p.pkgsrcs")]
    asserts.equals(env, "p", package_for("pkg/p.pkgsrcs", pkgs))
    return unittest.end(env)

def _package_for_external_and_nomatch_test_impl(ctx):
    # External-repo lib_root prefix matches; an unrelated path matches nothing.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("foo", "../pub/foo")]
    asserts.equals(env, "foo", package_for("../pub/foo/lib/x.dart", pkgs))
    asserts.equals(env, None, package_for("other/lib/x.dart", pkgs))
    return unittest.end(env)

def _colocate_loose_passthrough_test_impl(ctx):
    # A transitive source whose package is not in `packages` (e.g. a pub
    # transitive dep that rides along in transitive_srcs) is already co-located
    # in its own source location — it must pass through as a compile input, not
    # abort the build. No assembly is triggered here (all inputs are source).
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("myapp", "myapp")]
    matched = _fake_src("myapp/lib/a.dart")
    loose = _fake_src("../rules_dart++pub+dart_pub__meta/lib/meta.dart")
    packages2, srcs2 = colocate_packages(ctx, pkgs, [matched, loose])
    asserts.true(env, loose in srcs2, "loose pub source must pass through")
    asserts.true(env, matched in srcs2, "matched source must pass through")
    asserts.equals(env, 1, len(packages2))
    asserts.equals(env, "myapp", packages2[0].package_name)
    return unittest.end(env)

def _assembled_package_for_with_language_version_test_impl(ctx):
    env = unittest.begin(ctx)
    p = struct(package_name = "pkg", lib_root = "old/root", language_version = "2.12")
    out = assembled_package_for(p, "bazel-out/k8/bin/app.pkg.pkgsrcs")
    asserts.equals(env, "pkg", out.package_name)
    asserts.equals(env, "bazel-out/k8/bin/app.pkg.pkgsrcs", out.lib_root)
    asserts.equals(env, "2.12", out.language_version)
    return unittest.end(env)

def _assembled_package_for_without_language_version_test_impl(ctx):
    env = unittest.begin(ctx)
    p = struct(package_name = "pkg", lib_root = "old/root")
    out = assembled_package_for(p, "bazel-out/k8/bin/app.pkg.pkgsrcs")
    asserts.equals(env, "pkg", out.package_name)
    asserts.equals(env, "bazel-out/k8/bin/app.pkg.pkgsrcs", out.lib_root)
    asserts.equals(env, "", out.language_version)
    return unittest.end(env)

_assembled_with_lv_test = unittest.make(_assembled_package_for_with_language_version_test_impl)
_assembled_without_lv_test = unittest.make(_assembled_package_for_without_language_version_test_impl)
_all_source_test = unittest.make(_all_source_no_assembly_test_impl)
_any_generated_test = unittest.make(_any_generated_needs_assembly_test_impl)
_empty_test = unittest.make(_empty_no_assembly_test_impl)
_root_pkg_test = unittest.make(_package_for_root_package_test_impl)
_longest_prefix_test = unittest.make(_package_for_longest_prefix_test_impl)
_exact_dir_test = unittest.make(_package_for_exact_dir_test_impl)
_external_nomatch_test = unittest.make(_package_for_external_and_nomatch_test_impl)
_colocate_loose_test = unittest.make(_colocate_loose_passthrough_test_impl)

def source_set_test_suite(name):
    """Registers the source-assembly helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _all_source_test(name = "source_set_all_source_test")
    _any_generated_test(name = "source_set_any_generated_test")
    _empty_test(name = "source_set_empty_test")
    _root_pkg_test(name = "source_set_package_for_root_test")
    _longest_prefix_test(name = "source_set_package_for_longest_test")
    _exact_dir_test(name = "source_set_package_for_exact_dir_test")
    _external_nomatch_test(name = "source_set_package_for_external_test")
    _colocate_loose_test(name = "source_set_colocate_loose_test")
    _assembled_with_lv_test(name = "source_set_assembled_with_lv_test")
    _assembled_without_lv_test(name = "source_set_assembled_without_lv_test")
    native.test_suite(
        name = name,
        tests = [
            ":source_set_all_source_test",
            ":source_set_any_generated_test",
            ":source_set_empty_test",
            ":source_set_package_for_root_test",
            ":source_set_package_for_longest_test",
            ":source_set_package_for_exact_dir_test",
            ":source_set_package_for_external_test",
            ":source_set_colocate_loose_test",
            ":source_set_assembled_with_lv_test",
            ":source_set_assembled_without_lv_test",
        ],
    )
