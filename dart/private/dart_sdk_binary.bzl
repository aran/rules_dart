"""A runnable target that exposes the Dart SDK binary via toolchain resolution.

Usage:
    bazel run @rules_dart//dart -- --version
    bazel run @rules_dart//dart -- analyze lib/
"""

load("//dart/private:common.bzl", "BASH_RUNFILES_ATTR", "BASH_RUNFILES_INIT")

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
{runfiles_init}
DART="$(rlocation "{dart}")"
if [[ -n "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then
  cd "$BUILD_WORKING_DIRECTORY"
fi
exec "$DART" "$@"
""".format(
            runfiles_init = BASH_RUNFILES_INIT,
            dart = dart_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = dart_sdk_info.tool_files)
    runfiles = runfiles.merge(ctx.attr._runfiles_lib[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

dart_sdk_binary = rule(
    implementation = _dart_sdk_binary_impl,
    attrs = BASH_RUNFILES_ATTR,
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Exposes the Dart SDK binary from the resolved toolchain as a runnable target.",
)
