"""Implementation of the dart_format_test rule."""

def _runfiles_path(f, workspace_name):
    """Convert a File to its path in the runfiles tree."""
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def _dart_format_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    srcs = ctx.files.srcs
    dart_path = _runfiles_path(dart_sdk_info.dart, workspace_name)

    # Build list of source file paths in runfiles
    src_paths = []
    for src in srcs:
        src_paths.append('"$RUNFILES/' + _runfiles_path(src, workspace_name) + '"')

    test_runner = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = test_runner,
        content = """#!/usr/bin/env bash
set -euo pipefail
RUNFILES="${{RUNFILES_DIR:-$0.runfiles}}"
exec "$RUNFILES/{dart}" format --output=none --set-exit-if-changed {srcs}
""".format(
            dart = dart_path,
            srcs = " ".join(src_paths),
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = list(srcs) + dart_sdk_info.tool_files)

    return [
        DefaultInfo(
            executable = test_runner,
            runfiles = runfiles,
        ),
    ]

dart_format_test = rule(
    implementation = _dart_format_test_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files (`.dart`) to check. Typically `glob([\"lib/**/*.dart\"])`.",
            allow_files = [".dart"],
            mandatory = True,
        ),
    },
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Checks that Dart source files match `dart format` output. Fails if any file would be changed by formatting.",
)
