"""Unit tests for the native code-asset helpers in common.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:common.bzl", "generate_native_assets_yaml")

def _single_asset_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_native_assets_yaml(
        "macos_arm64",
        [("package:sqlite3/src/ffi/libsqlite3.g.dart", "../ext/sqlite3/libsqlite3.dylib")],
    )
    asserts.equals(
        env,
        '{"format-version": [1, 0, 0], "native-assets": {"macos_arm64": ' +
        '{"package:sqlite3/src/ffi/libsqlite3.g.dart": ["relative", "../ext/sqlite3/libsqlite3.dylib"]}}}\n',
        result,
    )
    return unittest.end(env)

def _multi_asset_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_native_assets_yaml(
        "linux_x64",
        [("a", "liba.so"), ("b", "../x/libb.so")],
    )
    asserts.true(env, '"native-assets": {"linux_x64": {' in result)
    asserts.true(env, '"a": ["relative", "liba.so"]' in result)
    asserts.true(env, '"b": ["relative", "../x/libb.so"]' in result)
    return unittest.end(env)

def _empty_assets_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_native_assets_yaml("windows_x64", [])
    asserts.equals(
        env,
        '{"format-version": [1, 0, 0], "native-assets": {"windows_x64": {}}}\n',
        result,
    )
    return unittest.end(env)

_t0_test = unittest.make(_single_asset_test_impl)
_t1_test = unittest.make(_multi_asset_test_impl)
_t2_test = unittest.make(_empty_assets_test_impl)

def native_assets_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test)
