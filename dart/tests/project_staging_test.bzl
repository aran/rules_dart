"""Unit tests for project_staging.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:project_staging.bzl", "in_place_root", "main_package_roots", "project_layout", "pubspec_stub", "staged_package_config_content")
load(":small_suite.bzl", "small_unittest_suite")

def _pkg(name, language_version = "", lib_root = ""):
    return struct(package_name = name, language_version = language_version, lib_root = lib_root)

def _file(short_path):
    if short_path.startswith("../"):
        return struct(short_path = short_path, path = "external/" + short_path[3:])
    return struct(short_path = short_path, path = short_path)

def _paths(files):
    return sorted([f.short_path for f in files])

def _sdk_from_language_version_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5"), _pkg("other")]
    asserts.true(env, 'sdk: "^3.5.0"' in pubspec_stub(pkgs, name = "app"))
    return unittest.end(env)

def _sdk_default_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5"), _pkg("other")]
    asserts.true(env, 'sdk: ">=3.0.0 <4.0.0"' in pubspec_stub(pkgs, name = "other"))
    asserts.true(env, 'sdk: ">=3.0.0 <4.0.0"' in pubspec_stub(pkgs))
    return unittest.end(env)

def _sdk_toolchain_version_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5"), _pkg("other")]
    asserts.true(env, 'sdk: "^3.11.0"' in pubspec_stub(pkgs, name = "other", sdk_version = "3.11.2"))
    asserts.true(env, 'sdk: "^3.11.0"' in pubspec_stub(pkgs, sdk_version = "3.11.2"))
    asserts.true(env, 'sdk: "^3.5.0"' in pubspec_stub(pkgs, name = "app", sdk_version = "3.11.2"))
    return unittest.end(env)

def _layout_home_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [
        _pkg("app", lib_root = "app"),
        _pkg("util", lib_root = "util"),
        _pkg("path", lib_root = "../+pub+path"),
    ]
    test = _file("app/test/a_test.dart")
    files = [
        _file("app/lib/app.dart"),
        test,
        _file("util/lib/util.dart"),
        _file("../+pub+path/lib/path.dart"),
        _file("analysis_options.yaml"),
        _file("../+pub+path/README.md"),
    ]
    layout = project_layout(pkgs, files, [test])

    # The checked file's package is copied in with the loose options file;
    # dependencies, in-repo or pub, stay where they are.
    asserts.equals(env, {("app", "app"): True}, layout.home)
    asserts.equals(
        env,
        ["analysis_options.yaml", "app/lib/app.dart", "app/test/a_test.dart"],
        _paths(layout.src_files),
    )
    asserts.equals(
        env,
        {("util", "util"): ["util/lib/util.dart"], ("path", "../+pub+path"): ["../+pub+path/lib/path.dart"]},
        {k: _paths(v) for k, v in layout.dep_files.items()},
    )
    asserts.equals(env, [("app", "app")], main_package_roots(layout))
    return unittest.end(env)

def _layout_deepest_root_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("root"), _pkg("inner", lib_root = "pkgs/inner")]
    entry = _file("pkgs/inner/bin/main.dart")
    layout = project_layout(pkgs, [entry, _file("lib/root.dart")], [entry])

    # The nested package's root holds the entrypoint, not the root package's.
    asserts.equals(env, {("inner", "pkgs/inner"): True}, layout.home)
    asserts.equals(env, {("root", ""): ["lib/root.dart"]}, {k: _paths(v) for k, v in layout.dep_files.items()})
    return unittest.end(env)

def _config_skips_unstaged_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5", lib_root = "app"), _pkg("gone", lib_root = "gone")]
    content = staged_package_config_content(pkgs, {("app", "app"): "../src/app"})
    asserts.true(env, '{"name": "app", "rootUri": "../src/app", "packageUri": "lib/", "languageVersion": "3.5"}' in content)
    asserts.false(env, "gone" in content)
    return unittest.end(env)

def _built(short_path, root):
    return struct(short_path = short_path, path = root + "/" + short_path, is_source = False, root = struct(path = root))

_OWN = "bazel-out/k8-fastbuild/bin"

def _in_place_test_impl(ctx):
    env = unittest.begin(ctx)
    src = struct(short_path = "dep/lib/a.dart", path = "dep/lib/a.dart", is_source = True, root = struct(path = ""))
    asserts.equals(env, "dep", in_place_root([src], "dep", _OWN))
    asserts.equals(env, _OWN + "/dep", in_place_root([_built("dep/lib/a.dart", _OWN)], "dep", _OWN))

    # Split between the source tree and `bazel-out`: no single root.
    asserts.equals(env, None, in_place_root([src, _built("dep/lib/b.dart", _OWN)], "dep", _OWN))

    # Built in another configuration: a relative path to it would name that
    # configuration, which path mapping does not rewrite in file contents.
    other = _built("dep/lib/a.dart", "bazel-out/k8-fastbuild-ST-0123/bin")
    asserts.equals(env, None, in_place_root([other], "dep", _OWN))
    return unittest.end(env)

_t0_test = unittest.make(_sdk_from_language_version_test_impl)
_t1_test = unittest.make(_sdk_default_test_impl)
_t2_test = unittest.make(_sdk_toolchain_version_test_impl)
_t3_test = unittest.make(_layout_home_test_impl)
_t4_test = unittest.make(_layout_deepest_root_test_impl)
_t5_test = unittest.make(_config_skips_unstaged_test_impl)
_t6_test = unittest.make(_in_place_test_impl)

def project_staging_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test)
