"""A launcher rule of another rule set, over `@rules_dart//dart:utils.bzl` alone.

`downstream_launcher` is what a launcher rule such as rules_flutter's is to
rules_dart: it carries the `data` of the libraries it depends on, runs its
program with the empty package config, and learns whether debugging information
is split, each through the public helper.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart:utils.bzl", "EMPTY_PACKAGE_CONFIG_ATTR", "SPLIT_DEBUG_INFO_ATTR", "collect_transitive_runfiles", "empty_package_config", "runfiles_path", "split_debug_info")

def _downstream_launcher_impl(ctx):
    packages = empty_package_config(ctx)
    config = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(config, "split_debug_info=%s\npackages=%s\n" % (
        split_debug_info(ctx),
        runfiles_path(packages, ctx.workspace_name),
    ))
    return [DefaultInfo(
        files = depset([config]),
        runfiles = ctx.runfiles(files = [config, packages]).merge(
            collect_transitive_runfiles(ctx, ctx.attr.deps),
        ),
    )]

downstream_launcher = rule(
    implementation = _downstream_launcher_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
    } | EMPTY_PACKAGE_CONFIG_ATTR | SPLIT_DEBUG_INFO_ATTR,
)
