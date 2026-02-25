"""Unit tests for common.bzl utilities."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:common.bzl", "generate_package_config_content")

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

_t0_test = unittest.make(_empty_packages_test_impl)
_t1_test = unittest.make(_single_package_test_impl)
_t2_test = unittest.make(_multiple_packages_test_impl)
_t3_test = unittest.make(_empty_lib_root_test_impl)

def common_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
