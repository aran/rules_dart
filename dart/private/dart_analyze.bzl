"""Implementation of the dart_analyze_test rule.

Runs `dart analyze` on a `dart_library` target as a Bazel test. The analysis
runs at build time as an action — if analysis fails, the build fails.
The test target itself is a trivial pass-through that always succeeds.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "collect_packages", "generate_package_config_content")

def _dart_analyze_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    lib_info = ctx.attr.lib[DartInfo]

    # Collect all packages (including the target itself) for package_config
    packages = collect_packages([ctx.attr.lib])

    # Generate package_config.json content with rootUri relative to .dart_tool/
    # (one level up from .dart_tool/ to project root)
    config_content = generate_package_config_content(packages, "..")

    # Write the package_config file
    package_config = ctx.actions.declare_file(ctx.label.name + ".analyze_config.json")
    ctx.actions.write(output = package_config, content = config_content)

    # Collect all transitive sources
    all_srcs = lib_info.transitive_srcs.to_list()

    # Build symlink commands: link each source file into the staging dir
    # This handles both root-package and sub-package cases correctly.
    symlink_cmds = []
    seen_paths = {}
    for src in all_srcs:
        src_path = src.path
        if src_path not in seen_paths:
            seen_paths[src_path] = True
            symlink_cmds.append(
                'mkdir -p "$PROJ/$(dirname {path})" && cp "$(pwd)/{path}" "$PROJ/{path}"'.format(
                    path = src_path,
                ),
            )

    # Copy analysis_options.yaml into the staging dir if provided.
    # The analyzer discovers it from the project root automatically.
    options_cmd = ""
    if ctx.attr.options:
        options_cmd = 'cp "$(pwd)/{options}" "$PROJ/analysis_options.yaml"'.format(
            options = ctx.file.options.path,
        )

    stamp = ctx.actions.declare_file(ctx.label.name + ".analyzed")

    cmd = """\
set -e
PROJ=$(mktemp -d)
trap 'rm -rf "$PROJ"' EXIT
export HOME="$PROJ"
export LOCALAPPDATA="$PROJ"
mkdir -p "$PROJ/.dart_tool"
cp "{config}" "$PROJ/.dart_tool/package_config.json"
printf 'name: __analyze__\\nenvironment:\\n  sdk: ">=3.0.0 <4.0.0"\\n' > "$PROJ/pubspec.yaml"
{options_cmd}
{symlinks}
"{dart}" analyze --fatal-infos "$PROJ"
touch "{stamp}"
""".format(
        config = package_config.path,
        dart = dart_sdk_info.dart.path,
        stamp = stamp.path,
        options_cmd = options_cmd,
        symlinks = "\n".join(symlink_cmds),
    )

    inputs = [package_config, dart_sdk_info.dart] + all_srcs + list(dart_sdk_info.tool_files)
    if ctx.attr.options:
        inputs.append(ctx.file.options)

    ctx.actions.run_shell(
        command = cmd,
        inputs = inputs,
        outputs = [stamp],
        mnemonic = "DartAnalyze",
        progress_message = "Analyzing Dart library %s" % ctx.label,
    )

    # Symlink the noop binary as the test executable.
    # The real validation happens in the build action above.
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.attr._tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    tool_runfiles = ctx.attr._tool[DefaultInfo].default_runfiles
    runfiles = ctx.runfiles(files = [stamp])
    runfiles = runfiles.merge(tool_runfiles)

    return [DefaultInfo(
        executable = executable,
        runfiles = runfiles,
    )]

dart_analyze_test = rule(
    implementation = _dart_analyze_test_impl,
    attrs = dict({
        "lib": attr.label(
            doc = "The `dart_library` target to analyze. All transitive sources are included.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "options": attr.label(
            doc = "An `analysis_options.yaml` file. If omitted, the Dart SDK's default analysis options are used.",
            allow_single_file = [".yaml"],
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:noop",
            executable = True,
            cfg = "exec",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs `dart analyze` on a Dart library as a build-time action. Fails the build if any analysis issues are found.",
)
