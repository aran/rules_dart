load("@bazel_skylib//rules:build_test.bzl", "build_test")
load(":rules.bzl", "probe")

probe(name = "probe")

# Property: the exported exec-group, tool and attribute helpers resolve to
# rules_dart's own targets from any module.
build_test(
    name = "exec_helpers_in_external_module_test",
    targets = [":probe"],
)
