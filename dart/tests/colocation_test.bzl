"""Unit tests for the generated-input co-location helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:common.bzl", "is_mixed_package")

def _fake_file(is_source):
    # is_mixed_package only inspects File.is_source.
    return struct(is_source = is_source)

def _pure_source_not_mixed_test_impl(ctx):
    # All source-tree files already share one real dir → not mixed.
    env = unittest.begin(ctx)
    asserts.false(env, is_mixed_package([_fake_file(True), _fake_file(True)]))
    return unittest.end(env)

def _fully_generated_not_mixed_test_impl(ctx):
    # All generated files already share one bin dir → not mixed.
    env = unittest.begin(ctx)
    asserts.false(env, is_mixed_package([_fake_file(False), _fake_file(False)]))
    return unittest.end(env)

def _mixed_is_mixed_test_impl(ctx):
    # A source file alongside a generated file → mixed (needs staging).
    env = unittest.begin(ctx)
    asserts.true(env, is_mixed_package([_fake_file(True), _fake_file(False)]))
    asserts.true(env, is_mixed_package([_fake_file(False), _fake_file(True)]))
    return unittest.end(env)

def _empty_not_mixed_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_mixed_package([]))
    return unittest.end(env)

_pure_source_test = unittest.make(_pure_source_not_mixed_test_impl)
_fully_generated_test = unittest.make(_fully_generated_not_mixed_test_impl)
_mixed_test = unittest.make(_mixed_is_mixed_test_impl)
_empty_test = unittest.make(_empty_not_mixed_test_impl)

def colocation_test_suite(name):
    """Registers the co-location helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _pure_source_test(name = "colocation_pure_source_test")
    _fully_generated_test(name = "colocation_fully_generated_test")
    _mixed_test(name = "colocation_mixed_test")
    _empty_test(name = "colocation_empty_test")
    native.test_suite(
        name = name,
        tests = [
            ":colocation_pure_source_test",
            ":colocation_fully_generated_test",
            ":colocation_mixed_test",
            ":colocation_empty_test",
        ],
    )
