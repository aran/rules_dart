"""Unit tests for dart_test.bzl helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_test.bzl", "format_packages_manifest_lines")

def _fake_pkg(package_name, lib_root, language_version):
    """A struct that mimics `DartPackageInfo`'s read surface."""
    return struct(
        package_name = package_name,
        lib_root = lib_root,
        language_version = language_version,
    )

def _language_version_present_test_impl(ctx):
    env = unittest.begin(ctx)
    pkg = _fake_pkg("rxdart", "pub/rxdart", "2.12")
    lines = format_packages_manifest_lines(
        [pkg],
        {"pub/rxdart": ("_main/pub/rxdart", "_main/pub/rxdart/lib/rxdart.dart")},
    )
    asserts.equals(env, 1, len(lines))
    asserts.equals(
        env,
        "rxdart\t_main/pub/rxdart\t_main/pub/rxdart/lib/rxdart.dart\t2.12",
        lines[0],
    )
    return unittest.end(env)

def _language_version_empty_test_impl(ctx):
    # An empty `language_version` must still emit the trailing tab so the
    # runtime parser sees a 4-column line with `parts[3] == ""` and can omit
    # `languageVersion` in the resulting JSON entry.
    env = unittest.begin(ctx)
    pkg = _fake_pkg("utils", "utils", "")
    lines = format_packages_manifest_lines(
        [pkg],
        {"utils": ("_main/utils", "_main/utils/lib/utils.dart")},
    )
    asserts.equals(env, 1, len(lines))
    asserts.equals(env, "utils\t_main/utils\t_main/utils/lib/utils.dart\t", lines[0])
    asserts.equals(env, 4, len(lines[0].split("\t")))
    return unittest.end(env)

def _missing_lib_root_skipped_test_impl(ctx):
    # No source file matched this package's lib_root, so no manifest line is
    # emitted — there's nothing in the runfiles tree to anchor it to.
    env = unittest.begin(ctx)
    pkg = _fake_pkg("ghost", "ghost", "3.0")
    lines = format_packages_manifest_lines([pkg], {})
    asserts.equals(env, [], lines)
    return unittest.end(env)

def _multiple_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("alpha", "alpha", "3.0"),
        _fake_pkg("beta", "pub/beta", ""),
    ]
    lines = format_packages_manifest_lines(
        pkgs,
        {
            "alpha": ("_main/alpha", "_main/alpha/lib/a.dart"),
            "pub/beta": ("_main/pub/beta", "_main/pub/beta/lib/b.dart"),
        },
    )
    asserts.equals(env, 2, len(lines))
    asserts.equals(env, "alpha\t_main/alpha\t_main/alpha/lib/a.dart\t3.0", lines[0])
    asserts.equals(env, "beta\t_main/pub/beta\t_main/pub/beta/lib/b.dart\t", lines[1])
    return unittest.end(env)

_lv_present_test = unittest.make(_language_version_present_test_impl)
_lv_empty_test = unittest.make(_language_version_empty_test_impl)
_missing_lib_root_test = unittest.make(_missing_lib_root_skipped_test_impl)
_multiple_test = unittest.make(_multiple_packages_test_impl)

def dart_test_test_suite(name):
    """Registers the dart_test.bzl helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _lv_present_test(name = "dart_test_lv_present_test")
    _lv_empty_test(name = "dart_test_lv_empty_test")
    _missing_lib_root_test(name = "dart_test_missing_lib_root_test")
    _multiple_test(name = "dart_test_multiple_test")
    native.test_suite(
        name = name,
        tests = [
            ":dart_test_lv_present_test",
            ":dart_test_lv_empty_test",
            ":dart_test_missing_lib_root_test",
            ":dart_test_multiple_test",
        ],
    )
