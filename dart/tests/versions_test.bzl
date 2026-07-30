"""Unit tests for starlark helpers
See https://bazel.build/rules/testing#testing-starlark-utilities
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:versions.bzl", "TOOL_VERSIONS")
load(":small_suite.bzl", "small_unittest_suite")

def _smoke_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.12.2", TOOL_VERSIONS.keys()[0])
    return unittest.end(env)

def _platforms_test_impl(ctx):
    env = unittest.begin(ctx)
    versions = TOOL_VERSIONS["3.12.2"]
    asserts.true(env, "macos-arm64" in versions)
    asserts.true(env, "macos-x64" in versions)
    asserts.true(env, "linux-x64" in versions)
    asserts.true(env, "linux-arm64" in versions)
    asserts.true(env, "windows-x64" in versions)
    asserts.equals(env, 5, len(versions))
    return unittest.end(env)

_t0_test = unittest.make(_smoke_test_impl)
_t1_test = unittest.make(_platforms_test_impl)

def versions_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test)
