"""Implementation of the dart_analyze_test rule.

Runs `dart analyze` on a dart_library target as a Bazel test. The analysis
runs at build time as an action -- if analysis fails, the build fails.
The test executable is a trivial pass-through.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "collect_packages", "generate_package_config_content")

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
                'mkdir -p "$PROJ/$(dirname {path})" && ln -sf "$(pwd)/{path}" "$PROJ/{path}"'.format(
                    path = src_path,
                ),
            )

    # Build the analysis command
    analyze_flags = "--fatal-infos"
    if ctx.attr.options:
        analyze_flags += ' --options="$(pwd)/{options}"'.format(
            options = ctx.file.options.path,
        )

    # Target the project root (analyze all symlinked sources)
    analyze_target = "$PROJ"

    stamp = ctx.actions.declare_file(ctx.label.name + ".analyzed")

    cmd = """\
set -e
PROJ=$(mktemp -d)
trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.dart_tool"
cp "{config}" "$PROJ/.dart_tool/package_config.json"
printf 'name: __analyze__\\nenvironment:\\n  sdk: ">=3.0.0 <4.0.0"\\n' > "$PROJ/pubspec.yaml"
{symlinks}
"{dart}" analyze {flags} "{target}"
touch "{stamp}"
""".format(
        config = package_config.path,
        dart = dart_sdk_info.dart.path,
        flags = analyze_flags,
        target = analyze_target,
        stamp = stamp.path,
        symlinks = "\n".join(symlink_cmds),
    )

    inputs = [package_config, dart_sdk_info.dart] + all_srcs + list(dart_sdk_info.tool_files)
    if ctx.attr.options:
        inputs.append(ctx.file.options)

    ctx.actions.run_shell(
        command = cmd,
        inputs = inputs,
        outputs = [stamp],
        env = {"HOME": "/tmp"},
        mnemonic = "DartAnalyze",
        progress_message = "Analyzing Dart library %s" % ctx.label,
    )

    # Create trivial test script -- the real validation happens in the build action above
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "#!/bin/bash\nexit 0\n",
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [stamp]),
    )]

dart_analyze_test = rule(
    implementation = _dart_analyze_test_impl,
    attrs = {
        "lib": attr.label(
            doc = "The dart_library target to analyze.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "options": attr.label(
            doc = "An analysis_options.yaml file.",
            allow_single_file = [".yaml"],
        ),
    },
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs `dart analyze` on a Dart library as a test target.",
)
