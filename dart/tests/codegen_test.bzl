"""Unit tests for dart_codegen.bzl output filename computation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_codegen.bzl", "compute_codegen_output_name")

def _g_dart_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("user.dart", ".g.dart")
    asserts.equals(env, "user.g.dart", result)
    return unittest.end(env)

def _freezed_suffix_with_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("some/dir/model.dart", ".freezed.dart")
    asserts.equals(env, "some/dir/model.freezed.dart", result)
    return unittest.end(env)

def _custom_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("router.dart", ".gr.dart")
    asserts.equals(env, "router.gr.dart", result)
    return unittest.end(env)

_t0_test = unittest.make(_g_dart_suffix_test_impl)
_t1_test = unittest.make(_freezed_suffix_with_dir_test_impl)
_t2_test = unittest.make(_custom_suffix_test_impl)

def codegen_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test)
