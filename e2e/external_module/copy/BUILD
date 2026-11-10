load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_dart//dart:defs.bzl", "dart_library")
load(":rules.bzl", "colocate")

genrule(
    name = "gen",
    outs = ["lib/gen.dart"],
    cmd = "echo 'const generated = 1;' > $@",
)

dart_library(
    name = "pkg",
    package_name = "pkg",
    srcs = [
        "lib/a.dart",
        ":gen",
    ],
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
