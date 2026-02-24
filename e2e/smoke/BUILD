"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

# Verify toolchain resolution works
build_test(
    name = "smoke_test",
    targets = [
        "@rules_dart//dart:resolved_toolchain",
    ],
)
