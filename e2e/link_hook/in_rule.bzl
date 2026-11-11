"""Rules that take a program's assets themselves, as a bundler does.

`in_rule_assets` links the program from inside its own implementation, as a
rule compiling its own kernel must; it is part of the package its `package`
names, whose assets and hook are the program's as a dependency's are.
`known_asset` names one asset of a program at analysis time.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartProgramAssetsInfo", "DartRecordedUsesInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "PORTABLE_EXEC_GROUPS",
    "PROGRAM_ASSETS_TOOLCHAINS",
    "dart_program_assets_actions",
    "executable_package_record",
    "package_identity_attrs",
    "program_asset_file",
    "program_assets_attrs",
    "resolve_package_identity",
)

def _own_package(ctx):
    identity = resolve_package_identity(ctx)
    return executable_package_record(ctx.label, identity) if identity.metadata != None else None

def _impl(ctx):
    result = dart_program_assets_actions(
        ctx,
        package = _own_package(ctx),
        deps = ctx.attr.deps,
        name = ctx.label.name,
        recorded_uses = ctx.attr.recorded_uses[DartRecordedUsesInfo],
    )
    return [
        DefaultInfo(files = depset([result.info.manifest], transitive = [result.info.files])),
        result.info,
        OutputGroupInfo(_validation = depset(result.validation_outputs)),
    ]

in_rule_assets = rule(
    implementation = _impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "recorded_uses": attr.label(providers = [DartRecordedUsesInfo]),
    } | package_identity_attrs() | program_assets_attrs(),
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
)

def _known_asset_impl(ctx):
    return [DefaultInfo(files = depset([program_asset_file(ctx.attr.assets[DartProgramAssetsInfo], ctx.attr.asset_id)]))]

known_asset = rule(
    implementation = _known_asset_impl,
    attrs = {
        "asset_id": attr.string(),
        "assets": attr.label(providers = [DartProgramAssetsInfo]),
    },
)
