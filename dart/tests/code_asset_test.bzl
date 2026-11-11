"""Analysis tests for `dart_code_asset` attribute validation.

Every invalid `link_mode` / attribute combination is a user-facing contract.
An untested `fail()` is a message nobody has ever read, so each one gets a
case here asserting both that it fires and what it says.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_code_asset")
load("//dart:providers.bzl", "DartCodeAssetInfo")

_ASSET_ID = "package:fixture/src/ffi/fixture.g.dart"
_SHARED_LIB = "//dart/tests/cc_fixture:empty_shared"
_PREBUILT = "//dart/tests/prebuilt_library_fixture:"

def _expect(msg):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, msg)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

_static_rejected_test = _expect("dart-lang/sdk/issues/49418")
_bundle_needs_library_test = _expect("requires `file`, a `cc_shared_library` or a prebuilt library file")
_bundle_rejects_uri_test = _expect("`uri` is only valid with")
_system_needs_uri_test = _expect("requires `uri =")
_system_rejects_library_test = _expect("`file` is only valid with")
_process_rejects_library_test = _expect("`file` is only valid with")
_executable_rejects_uri_test = _expect("`uri` is only valid with")
_prebuilt_wrong_platform_test = _expect("is not a dynamic library for the target platform")
_prebuilt_not_a_library_test = _expect("is not a dynamic library for the target platform")
_prebuilt_two_files_test = _expect("nor a single prebuilt library file; it has 2 files")
_system_rejects_prebuilt_test = _expect("`file` is only valid with")

def _prebuilt_carried_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    asserts.equals(env, "dynamic_loading_bundle", info.link_mode)
    asserts.true(env, info.file != None, "no file")
    asserts.equals(env, ctx.attr.basename, info.file.basename)
    return analysistest.end(env)

_prebuilt_carried_test = analysistest.make(
    _prebuilt_carried_impl,
    attrs = {"basename": attr.string()},
)

# A library of the target platform, and one of another.
_RIGHT_PLATFORM = select({
    "@platforms//os:windows": _PREBUILT + "libwrong.dll",
    "@platforms//os:macos": _PREBUILT + "libwrong.dylib",
    "//conditions:default": _PREBUILT + "libwrong.so",
})
_WRONG_PLATFORM = select({
    "@platforms//os:windows": _PREBUILT + "libwrong.so",
    "//conditions:default": _PREBUILT + "libwrong.dll",
})

def code_asset_test_suite(name):
    """Declares the `dart_code_asset` validation fixtures and their tests.

    Args:
      name: Name of the generated `test_suite`.
    """

    # `static` is in the attr's `values` (so the rule can produce a useful
    # message) but is rejected by the implementation.
    dart_code_asset(
        name = "ca_static",
        asset_id = _ASSET_ID,
        link_mode = "static",
        file = _SHARED_LIB,
        tags = ["manual"],
    )
    _static_rejected_test(
        name = "static_rejected_test",
        size = "small",
        target_under_test = ":ca_static",
    )

    dart_code_asset(
        name = "ca_bundle_no_library",
        asset_id = _ASSET_ID,
        tags = ["manual"],
    )
    _bundle_needs_library_test(
        name = "bundle_needs_library_test",
        size = "small",
        target_under_test = ":ca_bundle_no_library",
    )

    dart_code_asset(
        name = "ca_bundle_with_uri",
        asset_id = _ASSET_ID,
        file = _SHARED_LIB,
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _bundle_rejects_uri_test(
        name = "bundle_rejects_uri_test",
        size = "small",
        target_under_test = ":ca_bundle_with_uri",
    )

    dart_code_asset(
        name = "ca_system_no_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        tags = ["manual"],
    )
    _system_needs_uri_test(
        name = "system_needs_uri_test",
        size = "small",
        target_under_test = ":ca_system_no_uri",
    )

    dart_code_asset(
        name = "ca_system_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        file = _SHARED_LIB,
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _system_rejects_library_test(
        name = "system_rejects_library_test",
        size = "small",
        target_under_test = ":ca_system_with_library",
    )

    dart_code_asset(
        name = "ca_process_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_process",
        file = _SHARED_LIB,
        tags = ["manual"],
    )
    _process_rejects_library_test(
        name = "process_rejects_library_test",
        size = "small",
        target_under_test = ":ca_process_with_library",
    )

    dart_code_asset(
        name = "ca_executable_with_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_executable",
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _executable_rejects_uri_test(
        name = "executable_rejects_uri_test",
        size = "small",
        target_under_test = ":ca_executable_with_uri",
    )

    dart_code_asset(
        name = "ca_prebuilt_wrong_platform",
        asset_id = _ASSET_ID,
        file = _WRONG_PLATFORM,
        tags = ["manual"],
    )
    _prebuilt_wrong_platform_test(
        name = "prebuilt_wrong_platform_test",
        size = "small",
        target_under_test = ":ca_prebuilt_wrong_platform",
    )

    dart_code_asset(
        name = "ca_prebuilt_not_a_library",
        asset_id = _ASSET_ID,
        file = _PREBUILT + "libwrong.txt",
        tags = ["manual"],
    )
    _prebuilt_not_a_library_test(
        name = "prebuilt_not_a_library_test",
        size = "small",
        target_under_test = ":ca_prebuilt_not_a_library",
    )

    dart_code_asset(
        name = "ca_prebuilt_two_files",
        asset_id = _ASSET_ID,
        file = _PREBUILT + "two_files",
        tags = ["manual"],
    )
    _prebuilt_two_files_test(
        name = "prebuilt_two_files_test",
        size = "small",
        target_under_test = ":ca_prebuilt_two_files",
    )

    dart_code_asset(
        name = "ca_system_with_prebuilt",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        file = _RIGHT_PLATFORM,
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _system_rejects_prebuilt_test(
        name = "system_rejects_prebuilt_test",
        size = "small",
        target_under_test = ":ca_system_with_prebuilt",
    )

    dart_code_asset(
        name = "ca_prebuilt",
        asset_id = _ASSET_ID,
        file = _RIGHT_PLATFORM,
        tags = ["manual"],
    )
    _prebuilt_carried_test(
        name = "prebuilt_carried_test",
        size = "small",
        basename = select({
            "@platforms//os:windows": "libwrong.dll",
            "@platforms//os:macos": "libwrong.dylib",
            "//conditions:default": "libwrong.so",
        }),
        target_under_test = ":ca_prebuilt",
    )

    native.test_suite(
        name = name,
        tests = [
            ":prebuilt_wrong_platform_test",
            ":prebuilt_not_a_library_test",
            ":prebuilt_two_files_test",
            ":system_rejects_prebuilt_test",
            ":prebuilt_carried_test",
            ":static_rejected_test",
            ":bundle_needs_library_test",
            ":bundle_rejects_uri_test",
            ":system_needs_uri_test",
            ":system_rejects_library_test",
            ":process_rejects_library_test",
            ":executable_rejects_uri_test",
        ],
    )
