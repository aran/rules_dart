"""A runnable target that exposes the Dart SDK binary via toolchain resolution.

Usage:
    bazel run @rules_dart//dart -- --version
    bazel run @rules_dart//dart -- analyze lib/
"""

load("//dart/private:common.bzl", "SDK_ENV", "launcher_executable", "runfiles_path")

visibility("//dart/...")

def _dart_sdk_binary_impl(ctx):
    dart_sdk_info = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info

    launcher = launcher_executable(ctx, ctx.attr._launcher)
    config = ctx.actions.declare_file(ctx.label.name + ".launcher.json")
    ctx.actions.write(
        output = config,
        content = json.encode({
            "executable": runfiles_path(dart_sdk_info.dart, ctx.workspace_name),
            "arguments": [],
            # The same as an action's: the SDK writes no telemetry into the
            # home of the user who runs it.
            "environment": SDK_ENV,
            # Paths the user gives are relative to where they ran `bazel run`.
            "working_directory": "invocation",
        }),
    )

    runfiles = ctx.runfiles(
        files = [config],
        transitive_files = dart_sdk_info.files.all,
    ).merge(launcher.runfiles)

    return [DefaultInfo(
        executable = launcher.executable,
        runfiles = runfiles,
    )]

dart_sdk_binary = rule(
    implementation = _dart_sdk_binary_impl,
    attrs = {
        "_launcher": attr.label(
            default = "//dart/private/tools:launcher",
            executable = True,
            cfg = "target",
        ),
    },
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Exposes the Dart SDK binary from the resolved toolchain as a runnable target.",
)
