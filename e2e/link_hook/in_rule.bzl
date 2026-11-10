"""Rules that collect a program's data assets themselves, as a bundler does.

`in_rule_assets` runs the link hooks, as a rule compiling its own kernel must;
`unlinked_assets` takes what a program ships when nothing links it. Each is
part of the package its `package` names, whose assets and hook are the
program's as a dependency's are.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartRecordedUsesInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "PORTABLE_EXEC_GROUPS",
    "collect_transitive_data_assets",
    "dart_link_hook_actions",
    "executable_package_record",
    "link_hook_runner_attr",
    "package_identity_attrs",
    "resolve_package_identity",
)

def _own_package(ctx):
    identity = resolve_package_identity(ctx)
    return executable_package_record(ctx.label, identity) if identity.metadata != None else None

def _impl(ctx):
    result = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        recorded_uses = ctx.attr.recorded_uses[DartRecordedUsesInfo].file,
        package = _own_package(ctx),
        package_files = ctx.attr.recorded_uses[DartRecordedUsesInfo].package_files,
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
    } | package_identity_attrs() | link_hook_runner_attr(),
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)

def _unlinked_impl(ctx):
    return [DefaultInfo(files = depset([a.file for a in collect_transitive_data_assets(_own_package(ctx), ctx.attr.deps)]))]

unlinked_assets = rule(
    implementation = _unlinked_impl,
    attrs = {"deps": attr.label_list(providers = [DartInfo])} | package_identity_attrs(),
)
