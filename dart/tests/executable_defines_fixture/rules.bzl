"""A VM program rule built, as a rule set outside rules_dart would build one, on `utils.bzl`.

Its `flavor` attribute implies `APP_FLAVOR`, which its dependencies' modules
and its entrypoint must both read. `mismatched_program` takes its `deps`
through another environment's transition than the one it reads back, which
the entry compile must refuse.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo", "DartKernelSdkInfo")
load(
    "//dart:utils.bzl",
    "KERNEL_TOOL_ATTR",
    "PORTABLE",
    "PORTABLE_EXEC_GROUPS",
    "collect_modules",
    "collect_packages",
    "dart_entry_kernel_action",
    "dart_info_no_package",
    "dart_link_kernel_action",
    "dart_module_aspect",
    "executable_defines_config",
    "non_dart_transition",
)

_aspect = dart_module_aspect(Label("//dart/private:vm_kernel_sdk"))

def _flavor_defines(attr):
    return ["APP_FLAVOR=" + attr.flavor] if attr.flavor else []

_FLAVORED = executable_defines_config(_flavor_defines)
_PLAIN = executable_defines_config()

def _program_impl(ctx):
    forwarder = ctx.actions.declare_file(ctx.label.name + ".main.dart")
    ctx.actions.write(forwarder, "import '%s' as program;\n\nvoid main() => program.main();\n" % ctx.file.main.basename)
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
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    dart_link_kernel_action(ctx, ctx.executable._kernel_tool, entry, linked, dill)
    return [DefaultInfo(files = depset([dill]))]

def _program_rule(deps_cfg, read_back):
    return rule(
        implementation = _program_impl,
        attrs = KERNEL_TOOL_ATTR | read_back.attrs | {
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

# What the entry compile refuses, with modules compiled whatever the command
# line says: under `--@rules_dart//dart:modular_kernel=false` there are none.
refused_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    attrs = {"message": attr.string(mandatory = True)},
    config_settings = {str(Label("//dart:modular_kernel")): True},
)
