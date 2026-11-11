"""Tests that another rule set gets the runtime helpers of `//dart:utils.bzl` as rules_dart's rules do."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]

    # `data` of a dependency's dependency, through `collect_transitive_runfiles`.
    asserts.true(env, ctx.attr.data_file in files, "%s missing from runfiles %s" % (ctx.attr.data_file, files))

    # The file `dart_binary` and `dart_test` launch with.
    asserts.true(env, "dart/private/tools/empty_package_config.json" in files, "the empty package config missing from runfiles %s" % files)
    written = analysistest.target_actions(env)[0].content
    asserts.true(env, "split_debug_info=%s\n" % ctx.attr.split in written, "unexpected: %s" % written)
    asserts.true(env, "packages=_main/dart/private/tools/empty_package_config.json\n" in written, "unexpected: %s" % written)
    return analysistest.end(env)

runtime_helpers_test = analysistest.make(
    _impl,
    attrs = {
        "data_file": attr.string(mandatory = True),
        "split": attr.string(default = "False"),
    },
)

runtime_helpers_split_test = analysistest.make(
    _impl,
    attrs = {
        "data_file": attr.string(mandatory = True),
        "split": attr.string(default = "True"),
    },
    config_settings = {str(Label("//dart:split_debug_info")): True},
)
