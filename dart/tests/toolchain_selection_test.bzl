"""Unit tests for the Dart toolchain version selection in the `dart` extension."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/private:toolchain_selection.bzl", "select_toolchain_version")
load(":small_suite.bzl", "small_unittest_suite")

def _req(version, is_root = False):
    return struct(version = version, is_root = is_root)

def _single_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.13.4", is_root = True)])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _latest_wins_numerically_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.9.0"), _req("3.13.4"), _req("3.10.1")])
    asserts.equals(env, "3.13.4", selection.version)
    return unittest.end(env)

def _root_version_selected_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.13.4", is_root = True), _req("3.12.2")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _dependencies_only_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.12.2"), _req("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_version_overridden_notes_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.12.2", is_root = True), _req("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(
        env,
        "Dart toolchain dart uses 3.13.4, not 3.12.2 requested by the root module, because a dependency requires it",
        selection.note,
    )
    return unittest.end(env)

_single_request_test = unittest.make(_single_request_test_impl)
_latest_wins_numerically_test = unittest.make(_latest_wins_numerically_test_impl)
_root_version_selected_is_silent_test = unittest.make(_root_version_selected_is_silent_test_impl)
_dependencies_only_is_silent_test = unittest.make(_dependencies_only_is_silent_test_impl)
_root_version_overridden_notes_test = unittest.make(_root_version_overridden_notes_test_impl)

def toolchain_selection_test_suite(name):
    small_unittest_suite(
        name,
        _single_request_test,
        _latest_wins_numerically_test,
        _root_version_selected_is_silent_test,
        _dependencies_only_is_silent_test,
        _root_version_overridden_notes_test,
    )
