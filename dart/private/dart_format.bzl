"""Implementation of the dart_format rule.

The `bazel run` counterpart of the `dart_analyze` aspect's format check: it
rewrites the files it is given with the settings the check applies to them.

`dart format` finds its settings in the `formatter:` section of the nearest
`analysis_options.yaml`, and resolves any `include: package:` URI in that file
through the nearest `.dart_tool/package_config.json`. A Bazel workspace usually
has no package config, so run over the workspace directly the formatter cannot
resolve a shared ruleset's include. It then warns and drops *every* key in the
file, the ones stated beside the include as well, and rewraps the code at stock
defaults. The check never sees this, because it formats a staged project whose
package config carries the ruleset.

So this rule stages the options the same way, with the same code
(`stage_config_project`): every options file `@rules_dart//dart:analysis_config`
lists, at its workspace path, the packages their `include:`s resolve against,
and the root options file that ends the formatter's walk up. The runner copies
that, and each named file at its workspace path, into a scratch project,
formats there, and writes back the files that changed. Each file therefore
meets the nearest listed options file above it, exactly as in the check, and
never an options file the config does not list.
"""

load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "runfiles_path")
load("//dart/private:dart_analyze_aspect.bzl", "DartAnalysisConfigInfo", "stage_config_project")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _dart_format_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    config = ctx.attr._config[DartAnalysisConfigInfo]
    staged = stage_config_project(ctx, config, [], [], [], ctx.label.name)

    # Runfiles locations rather than paths, so the runner finds them through the
    # manifest on Windows, where there is no runfiles tree to walk. The options
    # files are read from their sources rather than from the staged tree, whose
    # members a manifest does not list.
    run_config = ctx.actions.declare_file(ctx.label.name + ".format_config.json")
    ctx.actions.write(
        output = run_config,
        content = json.encode({
            "dart": runfiles_path(dart_sdk_info.dart, ctx.workspace_name),
            "root_options": runfiles_path(
                staged.proj_files["analysis_options.yaml"],
                ctx.workspace_name,
            ),
            "package_config": runfiles_path(staged.package_config, ctx.workspace_name),
            "options": [
                {
                    "file": runfiles_path(f, ctx.workspace_name),
                    "workspace_path": f.short_path,
                }
                for f in config.options_files
            ],
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
        files = list(staged.inputs) + config.options_files + [run_config, dart_sdk_info.dart],
        transitive_files = dart_sdk_info.tool_files,
    )
    runfiles = runfiles.merge(ctx.attr._format_writer[DefaultInfo].default_runfiles)

    config_key = runfiles_path(run_config, ctx.workspace_name)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        # `bazel run //:format -- lib` forwards only the user's arguments, so the
        # runner learns where its configuration is through the environment, as
        # `dart_fix`'s applier does.
        RunEnvironmentInfo(environment = {"DART_FORMAT_CONFIG": config_key}),
        # The same file by label, for a caller that runs the binary as `data`
        # and so does not get the environment above.
        OutputGroupInfo(dart_format_config = depset([run_config])),
    ]

dart_format = rule(
    implementation = _dart_format_impl,
    attrs = dict({
        "_config": attr.label(
            default = "//dart:analysis_config",
            providers = [DartAnalysisConfigInfo],
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
        "Formats Dart files in the workspace under `bazel run`, each with " +
        "the settings of the nearest `analysis_options.yaml` that " +
        "`@rules_dart//dart:analysis_config` lists — the ones the " +
        "`dart_analyze` aspect's format check applies. Arguments are the " +
        "files and directories to format, relative to the directory " +
        "`bazel run` was invoked from, plus optionally " +
        "`--language-version=<major>.<minor>` (default `latest`). The check " +
        "formats each target at its own package's language version, so pass " +
        "it for a package below 3.7, whose style differs."
    ),
)
