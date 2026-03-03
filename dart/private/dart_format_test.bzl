"""Implementation of the dart_format_test rule."""

load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "create_test_executable", "runfiles_path")

def _dart_format_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    srcs = ctx.files.srcs
    dart_path = runfiles_path(dart_sdk_info.dart, workspace_name)

    # Write a manifest file listing runfiles-relative paths of sources
    manifest = ctx.actions.declare_file(ctx.label.name + ".format_manifest")
    manifest_lines = []
    for src in srcs:
        manifest_lines.append(runfiles_path(src, workspace_name))
    ctx.actions.write(output = manifest, content = "\n".join(manifest_lines) + "\n")

    manifest_path = runfiles_path(manifest, workspace_name)

    # Create test executable from pre-compiled format checker
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = {
            "RULES_DART_DART": dart_path,
            "RULES_DART_FORMAT_MANIFEST": manifest_path,
        },
    )

    runfiles = ctx.runfiles(files = list(srcs) + [manifest] + dart_sdk_info.tool_files)
    runfiles = runfiles.merge(tool_runfiles)

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
    ]

dart_format_test = rule(
    implementation = _dart_format_test_impl,
    attrs = dict({
        "srcs": attr.label_list(
            doc = "Dart source files (`.dart`) to check. Typically `glob([\"lib/**/*.dart\"])`.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:format_checker",
            executable = True,
            cfg = "exec",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Checks that Dart source files match `dart format` output. Fails if any file would be changed by formatting.",
)
