"""Unit tests for the native code-asset helpers in common.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES")
load("//dart/private:common.bzl", "generate_native_assets_yaml", "native_assets_path_list")

_L = "//pkg:target"

def _bundle(path):
    return native_assets_path_list(_L, "dynamic_loading_bundle", path, "")

def _single_asset_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_native_assets_yaml(
        "macos_arm64",
        [("package:sqlite3/src/ffi/libsqlite3.g.dart", _bundle("../ext/sqlite3/libsqlite3.dylib"))],
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
        [("a", _bundle("liba.so")), ("b", _bundle("../x/libb.so"))],
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

# --- native_assets_path_list, one per link mode ---

def _path_list_bundle_test_impl(ctx):
    # A bundled library uses `relative`, resolved against the dill — NOT
    # `absolute`, which is what an app bundler like rules_flutter emits
    # against its own bundle layout.
    env = unittest.begin(ctx)
    asserts.equals(env, ["relative", "libfoo.so"], _bundle("libfoo.so"))
    return unittest.end(env)

def _path_list_system_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["system", "libsqlite3.so.0"],
        native_assets_path_list(_L, "dynamic_loading_system", "", "libsqlite3.so.0"),
    )
    return unittest.end(env)

def _path_list_executable_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["executable"],
        native_assets_path_list(_L, "dynamic_loading_executable", "", ""),
    )
    return unittest.end(env)

def _path_list_process_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["process"],
        native_assets_path_list(_L, "dynamic_loading_process", "", ""),
    )
    return unittest.end(env)

def _path_list_covers_vocabulary_test_impl(ctx):
    # Every link mode `dart_code_asset` accepts must produce a path list.
    # `common.bzl` also checks this at load time; this asserts the behaviour
    # rather than the table, so a mode mapped to a bogus payload key is caught.
    env = unittest.begin(ctx)
    for link_mode in CODE_ASSET_LINK_MODES:
        result = native_assets_path_list(_L, link_mode, "libfoo.so", "libfoo.so.0")
        asserts.true(env, len(result) >= 1, "empty path list for %s" % link_mode)
        asserts.true(env, result[0] != "", "empty path type for %s" % link_mode)
    return unittest.end(env)

def _manifest_mixed_link_modes_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_native_assets_yaml("linux_x64", [
        ("bundled", _bundle("libb.so")),
        ("sys", native_assets_path_list(_L, "dynamic_loading_system", "", "libc.so.6")),
        ("proc", native_assets_path_list(_L, "dynamic_loading_process", "", "")),
    ])
    asserts.true(env, '"bundled": ["relative", "libb.so"]' in result)
    asserts.true(env, '"sys": ["system", "libc.so.6"]' in result)
    asserts.true(env, '"proc": ["process"]' in result)
    return unittest.end(env)

_t0_test = unittest.make(_single_asset_test_impl)
_t1_test = unittest.make(_multi_asset_test_impl)
_t2_test = unittest.make(_empty_assets_test_impl)
_t3_test = unittest.make(_path_list_bundle_test_impl)
_t4_test = unittest.make(_path_list_system_test_impl)
_t5_test = unittest.make(_path_list_executable_test_impl)
_t6_test = unittest.make(_path_list_process_test_impl)
_t7_test = unittest.make(_path_list_covers_vocabulary_test_impl)
_t8_test = unittest.make(_manifest_mixed_link_modes_test_impl)

def native_assets_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
    )
