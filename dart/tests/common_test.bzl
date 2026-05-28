"""Unit tests for common.bzl utilities."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/private:common.bzl",
    "generate_package_config",
    "generate_package_config_content",
    "relative_path",
    "resolve_package_roots",
)

# --- generate_package_config_content tests (prefix-based) ---

def _empty_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_package_config_content([], "../..")
    asserts.equals(env, '{"configVersion": 2, "packages": []}\n', result)
    return unittest.end(env)

def _single_package_test_impl(ctx):
    env = unittest.begin(ctx)
    pkg = struct(package_name = "foo", lib_root = "foo")
    result = generate_package_config_content([pkg], "..")
    asserts.true(env, '"configVersion": 2' in result)
    asserts.true(env, '"name": "foo"' in result)
    asserts.true(env, '"rootUri": "../foo"' in result)
    asserts.true(env, '"packageUri": "lib/"' in result)
    return unittest.end(env)

def _multiple_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [
        struct(package_name = "alpha", lib_root = "alpha"),
        struct(package_name = "beta", lib_root = "path/to/beta"),
    ]
    result = generate_package_config_content(pkgs, "../..")
    asserts.true(env, '"name": "alpha"' in result)
    asserts.true(env, '"rootUri": "../../alpha"' in result)
    asserts.true(env, '"name": "beta"' in result)
    asserts.true(env, '"rootUri": "../../path/to/beta"' in result)
    return unittest.end(env)

def _empty_lib_root_test_impl(ctx):
    env = unittest.begin(ctx)
    pkg = struct(package_name = "root_pkg", lib_root = "")
    result = generate_package_config_content([pkg], "../..")
    asserts.true(env, '"rootUri": "../.."' in result)
    return unittest.end(env)

# --- relative_path tests ---

def _relative_path_same_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ".", relative_path("a/b", "a/b"))
    return unittest.end(env)

def _relative_path_sibling_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "../c", relative_path("a/b", "a/c"))
    return unittest.end(env)

def _relative_path_deep_to_shallow_test_impl(ctx):
    env = unittest.begin(ctx)

    # e.g., config at bazel-out/cfg/bin/app -> source at pkg
    asserts.equals(env, "../../../pkg", relative_path("bazel-out/cfg/bin", "pkg"))
    return unittest.end(env)

def _relative_path_same_prefix_test_impl(ctx):
    env = unittest.begin(ctx)

    # e.g., config at bazel-out/cfg/bin/e2e/greeter -> generated at bazel-out/cfg/bin/proto
    asserts.equals(env, "../../proto", relative_path("bazel-out/cfg/bin/e2e/greeter", "bazel-out/cfg/bin/proto"))
    return unittest.end(env)

def _relative_path_to_root_test_impl(ctx):
    env = unittest.begin(ctx)

    # from deep path to exec-root ("")
    asserts.equals(env, "../../../../..", relative_path("bazel-out/cfg/bin/e2e/greeter", ""))
    return unittest.end(env)

def _relative_path_from_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "a/b", relative_path("", "a/b"))
    return unittest.end(env)

# --- generate_package_config / resolve_package_roots tests (exec-root-relative) ---
#
# The exec-root variant takes real `File` objects and a `File` config-output —
# but only reads `short_path`, `path`, `is_directory`, and `dirname`. We fake
# them with `struct`, matching the idiom in `source_set_test.bzl`.

def _fake_pkg(package_name, lib_root):
    return struct(package_name = package_name, lib_root = lib_root)

def _fake_src(short_path, path = None, is_directory = False):
    return struct(
        short_path = short_path,
        path = path if path != None else short_path,
        is_directory = is_directory,
    )

def _fake_config(dirname):
    return struct(dirname = dirname)

def _resolve_skips_source_less_test_impl(ctx):
    # `resolve_package_roots` only registers packages it can locate an
    # exec-root for. A package whose lib_root is non-empty but contributes
    # zero files to `all_srcs` must be absent from the returned dict.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("present_pkg", "present_pkg"),
        _fake_pkg("missing_pkg", "external/missing_pkg"),
    ]
    srcs = [_fake_src("present_pkg/lib/x.dart")]
    roots = resolve_package_roots(pkgs, srcs)
    asserts.true(env, "present_pkg" in roots)
    asserts.false(env, "missing_pkg" in roots, "source-less package must not be in roots")
    return unittest.end(env)

def _gpc_source_less_lib_root_skipped_test_impl(ctx):
    # Regression for the bug surfaced from rules_flutter: a package with a
    # non-empty lib_root but no Dart sources in the transitive closure
    # (asset/font-only pub deps like cupertino_icons, aggregate
    # `dart_library(srcs = [])` facades) must be silently omitted from the
    # generated package_config — not a fatal Starlark fail. If anything later
    # tries to import `package:<name>/…`, the Dart frontend reports a
    # localized URI-not-found at the import.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("present_pkg", "present_pkg"),
        _fake_pkg("missing_pkg", "external/missing_pkg"),
    ]
    srcs = [_fake_src("present_pkg/lib/x.dart")]
    result = generate_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"name": "present_pkg"' in result)
    asserts.false(env, '"name": "missing_pkg"' in result, "source-less package must be omitted")
    return unittest.end(env)

def _gpc_all_source_less_test_impl(ctx):
    # Every package source-less: result is a well-formed package_config with
    # an empty `packages` array — never a Starlark fail.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("ghost", "external/ghost")]
    result = generate_package_config(pkgs, [], _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"configVersion": 2' in result)
    asserts.true(env, '"packages": [' in result)
    asserts.false(env, '"name": "ghost"' in result)
    return unittest.end(env)

def _gpc_root_package_no_srcs_still_falls_back_test_impl(ctx):
    # Regression guard: a root package (empty lib_root) with no sources keeps
    # its depth-based fallback rootUri. This path is distinct from the
    # source-less-non-root case and must keep working.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("root", "")]
    result = generate_package_config(pkgs, [], _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"name": "root"' in result)
    asserts.true(env, '"rootUri":' in result)
    return unittest.end(env)

def _gpc_mixed_root_real_and_source_less_test_impl(ctx):
    # Root package + a real non-root package + a source-less non-root
    # package: the result lists the first two and omits the third.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("root", ""),
        _fake_pkg("real", "real"),
        _fake_pkg("ghost", "external/ghost"),
    ]
    srcs = [
        _fake_src("lib/main.dart"),
        _fake_src("real/lib/r.dart"),
    ]
    result = generate_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"name": "root"' in result)
    asserts.true(env, '"name": "real"' in result)
    asserts.false(env, '"name": "ghost"' in result)
    return unittest.end(env)

_t0_test = unittest.make(_empty_packages_test_impl)
_t1_test = unittest.make(_single_package_test_impl)
_t2_test = unittest.make(_multiple_packages_test_impl)
_t3_test = unittest.make(_empty_lib_root_test_impl)
_t4_test = unittest.make(_relative_path_same_dir_test_impl)
_t5_test = unittest.make(_relative_path_sibling_test_impl)
_t6_test = unittest.make(_relative_path_deep_to_shallow_test_impl)
_t7_test = unittest.make(_relative_path_same_prefix_test_impl)
_t8_test = unittest.make(_relative_path_to_root_test_impl)
_t9_test = unittest.make(_relative_path_from_empty_test_impl)
_t10_test = unittest.make(_resolve_skips_source_less_test_impl)
_t11_test = unittest.make(_gpc_source_less_lib_root_skipped_test_impl)
_t12_test = unittest.make(_gpc_all_source_less_test_impl)
_t13_test = unittest.make(_gpc_root_package_no_srcs_still_falls_back_test_impl)
_t14_test = unittest.make(_gpc_mixed_root_real_and_source_less_test_impl)

def common_test_suite(name):
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
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
    )
