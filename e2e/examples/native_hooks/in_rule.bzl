"""Rules that take a program's assets themselves, as a bundler does.

`in_rule_assets` links the program from inside its own implementation, as a
rule compiling its own kernel must; it is part of the package its `package`
names, whose assets and hook are the program's as a dependency's are.
`known_asset` names one asset of a program at analysis time. `read_assets` is
a consumer of what a program ships that runs path-mapped, as a bundler shared
across configurations does: through `program_assets_action_args()` and
`ProgramAssets.read`, it opens every file the program ships of what it is
handed: the data assets, the code assets with their libraries, or the code
assets by name, whose libraries it is not given.
"""

load("@rules_dart//dart:defs.bzl", "dart_test")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartProgramAssetsInfo", "DartRecordedUsesInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "PATH_MAPPING",
    "PORTABLE",
    "PORTABLE_EXEC_GROUPS",
    "PROGRAM_ASSETS_TOOLCHAINS",
    "dart_program_assets_actions",
    "executable_package_record",
    "package_identity_attrs",
    "program_asset_file",
    "program_assets_action_args",
    "program_assets_attrs",
    "resolve_package_identity",
    "vm_code_config",
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
        code_config = vm_code_config(ctx),
    )
    return [
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
    fragments = ["cpp"],
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

def _read_assets_impl(ctx):
    info = ctx.attr.assets[DartProgramAssetsInfo]
    report = ctx.actions.declare_file(ctx.label.name + ".txt")
    args = ctx.actions.args()
    args.add(report, format = "--output=%s")
    code = ctx.attr.code if ctx.attr.code != "none" else None
    assets = program_assets_action_args(ctx.actions, info, data = ctx.attr.data, code = code)
    ctx.actions.run(
        executable = ctx.executable._reader,
        arguments = [args, assets.args],
        inputs = assets.inputs,
        outputs = [report],
        mnemonic = "ReadAssets",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
    )
    return [DefaultInfo(files = depset([report]))]

read_assets = rule(
    implementation = _read_assets_impl,
    attrs = {
        "assets": attr.label(providers = [DartProgramAssetsInfo]),
        "code": attr.string(default = "libraries"),
        "data": attr.bool(default = True),
        "_reader": attr.label(
            default = "//native_hooks:read_assets",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
)

def assets_test(name, assets, expected, data = True, code = "libraries"):
    """Tests what a program ships, by what a path-mapped consumer of it reads.

    Args:
      name: The test's name.
      assets: The `dart_program_assets` target.
      expected: `<id>=<content>` for each data asset, `<id>` for each code asset.
      data: Whether the consumer is handed the data assets.
      code: What it is handed of the code assets: `libraries`, `names` or
        `none`.
    """
    read_assets(name = name + "_report", assets = assets, code = code, data = data, testonly = True)
    dart_test(
        name = name,
        size = "small",
        args = ["$(rlocationpath :%s_report)" % name] + expected,
        data = [":%s_report" % name],
        main = "assets_test.dart",
        deps = ["@rules_dart//dart/runfiles"],
    )
