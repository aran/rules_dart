"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_dart//dart:defs.bzl", "dart_test")

# Verify toolchain resolution works
build_test(
    name = "smoke_test",
    targets = [
        "@rules_dart//dart:resolved_toolchain",
    ],
)

# Verify the dart SDK binary is runnable
dart_test(
    name = "dart_version_test",
    size = "small",
    args = ["$(rlocationpath @rules_dart//dart)"],
    data = ["@rules_dart//dart"],
    main = "dart_version_test.dart",
    deps = ["@rules_dart//dart/runfiles"],
)
