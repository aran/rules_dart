load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")
load(":rules.bzl", "colocate")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "pkg",
)

genrule(
    name = "gen",
    outs = ["lib/gen.dart"],
    cmd = "echo 'const generated = 1;' > $@",
)

dart_library(
    name = "pkg",
    srcs = [
        "lib/a.dart",
        ":gen",
    ],
    package = ":pubspec-metadata",
)

colocate(
    name = "colocated",
    deps = [":pkg"],
)

# Property: a rule in another module can use the exported toolchain list and
# `colocate_packages` whatever it calls its own dependencies.
build_test(
    name = "colocate_in_external_module_test",
    targets = [":colocated"],
)
