"""A rule defined outside rules_dart that uses its exported exec-group helpers."""

load(
    "@rules_dart//dart:utils.bzl",
    "DART_TOOLCHAIN_TYPES_ATTR",
    "EXEC_TOOLS_TOOLCHAIN",
    "KERNEL_TOOL_ATTR",
    "PORTABLE",
    "PORTABLE_EXEC_GROUPS",
    "program_assets_attrs",
)

def _probe_impl(ctx):
    sdk = ctx.exec_groups[PORTABLE].toolchains[EXEC_TOOLS_TOOLCHAIN]
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "%s %s %s" % (
        sdk != None,
        ctx.executable._kernel_tool.short_path,
        ctx.executable._link_hook_runner.short_path,
    ))
    return [DefaultInfo(files = depset([out]))]

probe = rule(
    implementation = _probe_impl,
    attrs = {
        DART_TOOLCHAIN_TYPES_ATTR: attr.label_list(default = [Label("@rules_dart//dart:toolchain_type")]),
    } | KERNEL_TOOL_ATTR | program_assets_attrs(),
    exec_groups = PORTABLE_EXEC_GROUPS,
)
