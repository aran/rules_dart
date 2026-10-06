"""A rule that runs link hooks itself, as a rule compiling its own kernel must."""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartRecordedUsesInfo")
load("@rules_dart//dart:utils.bzl", "dart_link_hook_actions", "link_hook_runner_attr")

def _impl(ctx):
    result = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        sdk = ctx.toolchains["@rules_dart//dart:exec_tools_toolchain_type"].dart_sdk_info,
        recorded_uses = ctx.attr.recorded_uses[DartRecordedUsesInfo].file,
        deps = ctx.attr.deps,
        data_asset_ids = ctx.attr.data_assets,
        name = ctx.label.name,
    )
    return [
        DefaultInfo(files = depset([a.file for a in result.assets])),
        OutputGroupInfo(_validation = depset(result.validation_outputs)),
    ]

in_rule_assets = rule(
    implementation = _impl,
    attrs = {
        "data_assets": attr.string_list(),
        "deps": attr.label_list(providers = [DartInfo]),
        "recorded_uses": attr.label(providers = [DartRecordedUsesInfo]),
    } | link_hook_runner_attr(),
    toolchains = ["@rules_dart//dart:exec_tools_toolchain_type"],
)
