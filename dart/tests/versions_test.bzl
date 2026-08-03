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

# The per-platform checksum coverage that used to live here — a hand-listed set
# plus `len(versions) == 5` — is now `toolchains_test.bzl`'s
# `_checksums_cover_every_host_test`, which checks every pinned version against
# `PLATFORMS` rather than one version against a literal count. A bare count
# cannot catch a *wrong* key, and it broke on every platform change.

_t0_test = unittest.make(_smoke_test_impl)

def versions_test_suite(name):
    small_unittest_suite(name, _t0_test)
