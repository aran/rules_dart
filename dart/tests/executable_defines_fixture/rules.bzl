"""A VM program rule built, as a rule set outside rules_dart would build one, on `utils.bzl`.

Its `flavor` attribute implies `APP_FLAVOR`, which its dependencies' modules
and its entrypoint must both read. Under `--@rules_dart//dart:modular_kernel=false`
it compiles its whole program from source instead. `mismatched_program` takes
its `deps` through another environment's transition than the one it reads
back, which the entry compile must refuse. `modules_only_program` compiles
against modules whatever the setting, which the entry compile must refuse
when there are none.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo", "DartKernelSdkInfo")
load(
    "//dart:utils.bzl",
    "KERNEL_TOOL_ATTR",
    "MODULAR_KERNEL_ATTR",
    "PORTABLE",
    "PORTABLE_EXEC_GROUPS",
    "collect_modules",
    "collect_packages",
    "collect_transitive_srcs",
    "dart_entry_kernel_action",
    "dart_info_no_package",
    "dart_link_kernel_action",
    "dart_module_aspect",
    "dart_whole_program_kernel_action",
    "executable_defines",
    "executable_defines_config",
    "modular_kernel",
    "non_dart_transition",
)

_aspect = dart_module_aspect(Label("//dart/private:vm_kernel_sdk"))

def _flavor_defines(attr):
    return ["APP_FLAVOR=" + attr.flavor] if attr.flavor else []

_FLAVORED = executable_defines_config(_flavor_defines)
_PLAIN = executable_defines_config()

def _program_impl(ctx, whole_program):
    forwarder = ctx.actions.declare_file(ctx.label.name + ".main.dart")
    ctx.actions.write(forwarder, "import '%s' as program;\n\nvoid main() => program.main();\n" % ctx.file.main.basename)
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    if whole_program and not modular_kernel(ctx):
        sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo]
        dart_whole_program_kernel_action(
            ctx,
            kernel_sdk = sdk,
            runtime = sdk.module_runtime,
            main = forwarder,
            srcs = depset([ctx.file.main], transitive = [collect_transitive_srcs(ctx.attr.deps)]),
            packages = collect_packages(ctx.attr.deps),
            output_dill = dill,
            defines = executable_defines(ctx),
        )
        return [DefaultInfo(files = depset([dill]))]
    entry = ctx.actions.declare_file(ctx.label.name + ".entry.dill")
    linked = dart_entry_kernel_action(
        ctx,
        sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
        kernel_tool = ctx.executable._kernel_tool,
        main = forwarder,
        srcs = [ctx.file.main],
        packages = collect_packages(ctx.attr.deps),
        modules = collect_modules(ctx.attr.deps),
        output = entry,
    )
    dart_link_kernel_action(ctx, ctx.executable._kernel_tool, entry, linked, dill)
    return [DefaultInfo(files = depset([dill]))]

def _whole_program_impl(ctx):
    return _program_impl(ctx, whole_program = True)

def _modules_only_impl(ctx):
    return _program_impl(ctx, whole_program = False)

def _program_rule(deps_cfg, read_back, implementation = _whole_program_impl):
    return rule(
        implementation = implementation,
        attrs = KERNEL_TOOL_ATTR | MODULAR_KERNEL_ATTR | read_back.attrs | {
            "main": attr.label(allow_single_file = [".dart"], mandatory = True),
            "deps": attr.label_list(providers = [DartInfo], aspects = [_aspect], cfg = deps_cfg.cfg),
            "defines": attr.string_list(),
            "flavor": attr.string(),
            "_extra_dart_defines": attr.label(default = Label("//dart:extra_dart_defines")),
            "_kernel_sdk": attr.label(
                default = Label("//dart/private:vm_kernel_sdk"),
                providers = [DartKernelSdkInfo],
                cfg = config.exec(PORTABLE),
            ),
        },
        exec_groups = PORTABLE_EXEC_GROUPS,
    )

flavored_program = _program_rule(_FLAVORED, _FLAVORED)
mismatched_program = _program_rule(_PLAIN, _FLAVORED)
modules_only_program = _program_rule(_FLAVORED, _FLAVORED, _modules_only_impl)

# A rule nothing of which is compiled Dart, reporting the environment it was
# configured in.
_EnvironmentInfo = provider(doc = "The environment a target was configured in.", fields = ["defines"])

def _reset_reader_impl(ctx):
    return [_EnvironmentInfo(defines = ctx.attr._module_defines[BuildSettingInfo].value)]

reset_reader = rule(
    implementation = _reset_reader_impl,
    cfg = non_dart_transition,
    attrs = {"_module_defines": attr.label(default = Label("//dart/private:module_defines"))},
)

# A Dart dependency configured without the environment that holds no modules,
# as a package of assets does.
def _reset_library_impl(_ctx):
    return [dart_info_no_package()]

reset_library = rule(
    implementation = _reset_library_impl,
    cfg = non_dart_transition,
)

def _reset_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, [], analysistest.target_under_test(env)[_EnvironmentInfo].defines)
    return analysistest.end(env)

reset_test = analysistest.make(
    _reset_test_impl,
    config_settings = {str(Label("//dart/private:module_defines")): ["APP_FLAVOR=prod"]},
)

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_MODULAR_KERNEL = str(Label("//dart:modular_kernel"))

# What the entry compile refuses, with modules compiled whatever the command
# line says, and without any.
refused_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    attrs = {"message": attr.string(mandatory = True)},
    config_settings = {_MODULAR_KERNEL: True},
)

refused_whole_program_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    attrs = {"message": attr.string(mandatory = True)},
    config_settings = {_MODULAR_KERNEL: False},
)
