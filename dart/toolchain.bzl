"""This module implements the Dart SDK toolchain rule."""

DartSdkInfo = provider(
    doc = "Information about the Dart SDK.",
    fields = {
        "dart": "The dart executable File.",
        "sdk_root": "The root directory of the Dart SDK.",
        "version": "The version string of the Dart SDK.",
        "tool_files": "All files required to make the SDK available at runtime.",
    },
)

def _dart_toolchain_impl(ctx):
    sdk_root = ctx.attr.sdk_root
    dart = ctx.attr.dart

    tool_files = ctx.attr.sdk_root.files.to_list()

    dart_sdk_info = DartSdkInfo(
        dart = ctx.file.dart,
        sdk_root = sdk_root,
        version = ctx.attr.version,
        tool_files = tool_files,
    )

    template_variables = platform_common.TemplateVariableInfo({
        "DART_BIN": ctx.file.dart.path,
    })
    default = DefaultInfo(
        files = depset(tool_files),
        runfiles = ctx.runfiles(files = tool_files),
    )

    toolchain_info = platform_common.ToolchainInfo(
        dart_sdk_info = dart_sdk_info,
        template_variables = template_variables,
        default = default,
    )
    return [
        default,
        toolchain_info,
        template_variables,
    ]

dart_toolchain = rule(
    implementation = _dart_toolchain_impl,
    attrs = {
        "dart": attr.label(
            doc = "The dart executable.",
            mandatory = True,
            allow_single_file = True,
        ),
        "sdk_root": attr.label(
            doc = "The root filegroup of the Dart SDK.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The version of the Dart SDK.",
            mandatory = True,
        ),
    },
    doc = "Defines a Dart SDK toolchain.",
)
