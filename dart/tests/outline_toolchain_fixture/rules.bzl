"""Tests that the VM's kernel SDK takes its outline stripper from the outline toolchain of its own SDK."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _registering(toolchain):
    return {"//command_line_option:extra_toolchains": [str(Label(toolchain))]}

def _refuses_other_version_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the outline toolchain is of the Dart 0.0.0 SDK, but the Dart toolchain is")
    return analysistest.end(env)

refuses_other_version_test = analysistest.make(
    _refuses_other_version_impl,
    expect_failure = True,
    config_settings = _registering(":other_version_toolchain"),
)

def _refuses_no_tool_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "has no `tool`, though `--@rules_dart//dart:outline_kernel` is on")
    return analysistest.end(env)

refuses_no_tool_test = analysistest.make(
    _refuses_no_tool_impl,
    expect_failure = True,
    config_settings = _registering(":no_tool_toolchain"),
)
