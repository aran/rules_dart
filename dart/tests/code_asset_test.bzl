"""Analysis tests for `dart_code_asset` attribute validation.

Every invalid `link_mode` / attribute combination is a user-facing contract.
An untested `fail()` is a message nobody has ever read, so each one gets a
case here asserting both that it fires and what it says.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_code_asset")

_ASSET_ID = "package:fixture/src/ffi/fixture.g.dart"
_SHARED_LIB = "//dart/tests/cc_fixture:empty_shared"

def _expect(msg):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, msg)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

_static_rejected_test = _expect("dart-lang/sdk/issues/49418")
_bundle_needs_library_test = _expect("requires `shared_library =")
_bundle_rejects_system_uri_test = _expect("`system_uri` is only valid with")
_system_needs_uri_test = _expect("requires `system_uri =")
_system_rejects_library_test = _expect("`shared_library` is only valid with")
_process_rejects_library_test = _expect("`shared_library` is only valid with")
_executable_rejects_system_uri_test = _expect("`system_uri` is only valid with")

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
        shared_library = _SHARED_LIB,
        tags = ["manual"],
    )
    _static_rejected_test(
        name = "static_rejected_test",
        target_under_test = ":ca_static",
    )

    dart_code_asset(
        name = "ca_bundle_no_library",
        asset_id = _ASSET_ID,
        tags = ["manual"],
    )
    _bundle_needs_library_test(
        name = "bundle_needs_library_test",
        target_under_test = ":ca_bundle_no_library",
    )

    dart_code_asset(
        name = "ca_bundle_with_system_uri",
        asset_id = _ASSET_ID,
        shared_library = _SHARED_LIB,
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _bundle_rejects_system_uri_test(
        name = "bundle_rejects_system_uri_test",
        target_under_test = ":ca_bundle_with_system_uri",
    )

    dart_code_asset(
        name = "ca_system_no_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        tags = ["manual"],
    )
    _system_needs_uri_test(
        name = "system_needs_uri_test",
        target_under_test = ":ca_system_no_uri",
    )

    dart_code_asset(
        name = "ca_system_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        shared_library = _SHARED_LIB,
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _system_rejects_library_test(
        name = "system_rejects_library_test",
        target_under_test = ":ca_system_with_library",
    )

    dart_code_asset(
        name = "ca_process_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_process",
        shared_library = _SHARED_LIB,
        tags = ["manual"],
    )
    _process_rejects_library_test(
        name = "process_rejects_library_test",
        target_under_test = ":ca_process_with_library",
    )

    dart_code_asset(
        name = "ca_executable_with_system_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_executable",
        system_uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _executable_rejects_system_uri_test(
        name = "executable_rejects_system_uri_test",
        target_under_test = ":ca_executable_with_system_uri",
    )

    native.test_suite(
        name = name,
        tests = [
            ":static_rejected_test",
            ":bundle_needs_library_test",
            ":bundle_rejects_system_uri_test",
            ":system_needs_uri_test",
            ":system_rejects_library_test",
            ":process_rejects_library_test",
            ":executable_rejects_system_uri_test",
        ],
    )
