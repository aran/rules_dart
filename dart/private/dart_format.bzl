"""Implementation of the dart_format rule.

The `bazel run` counterpart of `dart_format_test`: it rewrites the files it is
given with the same formatter settings the check applies.

`dart format` finds its settings in the `formatter:` section of the nearest
`analysis_options.yaml`, and resolves any `include: package:` URI in that file
through the nearest `.dart_tool/package_config.json`. A Bazel workspace usually
has no package config, so run over the workspace directly the formatter cannot
resolve a shared ruleset's include. It then warns and drops *every* key in the
file, the ones stated beside the include as well, and rewraps the code at stock
defaults. The check never sees this, because it formats a staged project whose
package config carries the ruleset.

So this rule stages that same project — the options file at its root, and the
packages a `dart_analysis_options` target carries — and puts it in runfiles.
The runner copies the named files into a scratch project built from it, formats
them there, and writes back the ones that changed. The formatter therefore
reads exactly the options the check reads, and never the workspace's own.
"""

load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "analysis_options_closure", "runfiles_path")
load("//dart/private:project_staging.bzl", "stage_dart_project", "stage_root_options")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _dart_format_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # The same closure and the same staging as `dart_format_test`, so a run and
    # a check over the same `options` cannot resolve different settings.
    opts = analysis_options_closure(ctx.attr.options)
    staged = stage_dart_project(ctx, opts.packages, opts.files)
    options_file = stage_root_options(ctx, ctx.file.options)

    # Runfiles locations rather than paths, so the runner finds them through the
    # manifest on Windows, where there is no runfiles tree to walk.
    config = ctx.actions.declare_file(ctx.label.name + ".format_config.json")
    ctx.actions.write(
        output = config,
        content = json.encode({
            "dart": runfiles_path(dart_sdk_info.dart, ctx.workspace_name),
            "options": runfiles_path(options_file, ctx.workspace_name),
            "package_config": runfiles_path(staged.package_config, ctx.workspace_name),
        }),
    )

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(
        ctx.label.name + (".exe" if is_windows else ""),
    )
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._format_writer,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = list(staged.inputs) + [options_file, config, dart_sdk_info.dart],
        transitive_files = dart_sdk_info.tool_files,
    )
    runfiles = runfiles.merge(ctx.attr._format_writer[DefaultInfo].default_runfiles)

    config_key = runfiles_path(config, ctx.workspace_name)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        # `bazel run //:format -- lib` forwards only the user's arguments, so the
        # runner learns where its configuration is through the environment, as
        # `dart_fix`'s applier does.
        RunEnvironmentInfo(environment = {"DART_FORMAT_CONFIG": config_key}),
        # The same file by label, for a caller that runs the binary as `data`
        # and so does not get the environment above.
        OutputGroupInfo(dart_format_config = depset([config])),
    ]

dart_format = rule(
    implementation = _dart_format_impl,
    attrs = dict({
        "options": attr.label(
            doc = (
                "A `dart_analysis_options` target, or a bare " +
                "`analysis_options.yaml`, whose `formatter:` section " +
                "(`page_width`, `trailing_commas`) governs the run. Give it " +
                "the same target as the matching `dart_format_test`. Use the " +
                "target form when the file `include`s a ruleset by " +
                "`package:` URI. If omitted, stock `dart format` defaults " +
                "apply, whatever options file sits above the sources."
            ),
            allow_single_file = [".yaml"],
        ),
        "_format_writer": attr.label(
            default = "//dart/private/tools:format_writer",
            executable = True,
            cfg = "target",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    executable = True,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = (
        "Formats Dart files in the workspace under `bazel run`, with the " +
        "settings from `options` — the same ones `dart_format_test` checks " +
        "against. Arguments are the files and directories to format, " +
        "relative to the directory `bazel run` was invoked from, plus " +
        "optionally `--language-version=<major>.<minor>` (default `latest`)."
    ),
)
