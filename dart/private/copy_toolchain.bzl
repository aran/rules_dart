"""The toolchain rule that provides the `copy_tree` tool.

`assemble_source_dir` in `source_set.bzl` copies files into a tree artifact by
running this tool. The toolchain is registered from `MODULE.bazel`, next to the
Dart SDK toolchain.
"""

def _copy_toolchain_impl(ctx):
    exec_sdk = ctx.toolchains["//dart:exec_tools_toolchain_type"].dart_sdk_info
    return [platform_common.ToolchainInfo(
        copy_tree = ctx.executable.tool,
        dart = exec_sdk.dart,
        runtime_files = exec_sdk.runtime_files,
    )]

copy_toolchain = rule(
    implementation = _copy_toolchain_impl,
    doc = "Provides the `copy_tree` tool under `//dart:copy_toolchain_type`.",
    attrs = {
        "tool": attr.label(
            doc = "The `copy_tree` tool, built for the exec platform.",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
    },
    toolchains = ["//dart:exec_tools_toolchain_type"],
)
