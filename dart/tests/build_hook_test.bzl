"""Tests for a first-party package's `build_hook`.

The analysis tests are declared beside their fixtures, in
`//dart/tests/build_hook_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:common.bzl", "merge_package_records")
load("//dart/private:dart_package_metadata.bzl", "build_hook_error", "unreplaced_build_hook")
load("//dart/private:package_info.bzl", "raw_dart_package_info")
load(":small_suite.bzl", "small_unittest_suite")

def _records_build_hook_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]
    hooks = [
        p.unreplaced_hook
        for p in info.transitive_packages.to_list()
        if p.package_name == "build_hook_fixture"
    ]
    asserts.equals(env, [ctx.attr.expected], hooks)
    return analysistest.end(env)

records_build_hook_test = analysistest.make(
    _records_build_hook_test_impl,
    attrs = {"expected": attr.string()},
)

def _analyzes_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

analyzes_test = analysistest.make(_analyzes_test_impl)

def _expect_failure(*fragments):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        for fragment in fragments:
            asserts.expect_failure(env, fragment)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

unreplaced_build_hook_test = _expect_failure(
    "build_hook_fixture (hook/build.dart)",
    "remove its `build_hook`",
    "in the `code_assets` of the package's",
)
misplaced_build_hook_test = _expect_failure("`build_hook` must be the package's `hook/build.dart`")

def _build_hook_location_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, build_hook_error("//a:b", "pkg", None))
    asserts.equals(env, None, build_hook_error("//a:b", "pkg", struct(short_path = "pkg/hook/build.dart")))
    asserts.equals(env, None, build_hook_error("//a:b", "", struct(short_path = "hook/build.dart")))
    err = build_hook_error("//a:b", "pkg", struct(short_path = "pkg/tool/build.dart"))
    asserts.true(env, err != None and "`pkg/hook/build.dart`" in err, err)
    return unittest.end(env)

_build_hook_location_test = unittest.make(_build_hook_location_test_impl)

def _unreplaced_build_hook_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", unreplaced_build_hook(None, []))
    asserts.equals(env, "hook/build.dart", unreplaced_build_hook(struct(), []))
    asserts.equals(env, "", unreplaced_build_hook(struct(), ["//a:asset"]))
    return unittest.end(env)

_unreplaced_build_hook_unit_test = unittest.make(_unreplaced_build_hook_test_impl)

# Built raw, not through `DartPackageInfo(...)`: that takes the assets as targets, and
# these tests have values.
def _record(package_root, hook = "", assets = ()):
    return raw_dart_package_info(
        label = None,
        package_name = "split",
        package_root = package_root,
        version = "",
        language_version = "",
        code_assets = assets,
        data_assets = (),
        unreplaced_hook = hook,
        link_hook = None,
        link_hook_assets = (),
        linked_code_assets = (),
        license_file = None,
        metadata = None,
    )

_ASSET = DartCodeAssetInfo(
    asset_id = "package:split/native.dart",
    link_mode = "dynamic_loading_process",
    file = None,
    uri = "",
)

def _merged_hook(records):
    return merge_package_records(records)[0].unreplaced_hook

def _merge_keeps_any_records_hook_test_impl(ctx):
    # A package split across targets states its `build_hook` on one of them,
    # whichever comes first in dependency order.
    env = unittest.begin(ctx)
    asserts.equals(env, "hook/build.dart", _merged_hook([_record("a"), _record("b", "hook/build.dart")]))
    asserts.equals(env, "hook/build.dart", _merged_hook([_record("a", "hook/build.dart"), _record("b")]))
    return unittest.end(env)

_merge_keeps_any_records_hook_test = unittest.make(_merge_keeps_any_records_hook_test_impl)

def _merge_any_records_assets_replace_hook_test_impl(ctx):
    # Code assets belong to the package: one target's replace the hook another
    # target states, and a hub curating them replaces the hook another hub
    # flags, in either order.
    env = unittest.begin(ctx)
    hooked = _record("a", "hook/build.dart")
    replaced = _record("b", assets = (_ASSET,))
    asserts.equals(env, "", _merged_hook([hooked, replaced]))
    asserts.equals(env, "", _merged_hook([replaced, hooked]))
    return unittest.end(env)

_merge_any_records_assets_replace_hook_test = unittest.make(_merge_any_records_assets_replace_hook_test_impl)

def build_hook_test_suite(name):
    """Registers the pure-helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    small_unittest_suite(
        name,
        _build_hook_location_test,
        _unreplaced_build_hook_unit_test,
        _merge_keeps_any_records_hook_test,
        _merge_any_records_assets_replace_hook_test,
    )
