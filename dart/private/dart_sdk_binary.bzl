"""A runnable target that exposes the Dart SDK binary via toolchain resolution.

Usage:
    bazel run @rules_dart//dart -- --version
    bazel run @rules_dart//dart -- analyze lib/
"""

def _runfiles_path(f, workspace_name):
    """Convert a File to its path in the runfiles tree."""
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def _dart_sdk_binary_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    dart_path = _runfiles_path(dart_sdk_info.dart, ctx.workspace_name)

    script = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = script,
        content = """#!/usr/bin/env bash
RUNFILES="${{RUNFILES_DIR:-$0.runfiles}}"
exec "$RUNFILES/{dart}" "$@"
""".format(dart = dart_path),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = dart_sdk_info.tool_files)

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

dart_sdk_binary = rule(
    implementation = _dart_sdk_binary_impl,
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Exposes the Dart SDK binary from the resolved toolchain as a runnable target.",
)
