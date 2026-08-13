"""Implementation of the dart_analyze_test rule.

Runs `dart analyze` on a `dart_library` target as a Bazel test. The analysis
runs at build time as an action — if analysis fails, the build fails. The test
target itself is a trivial pass-through that always succeeds.

The analyzer wants a project directory (pubspec.yaml, .dart_tool/, sources),
which is staged hermetically from declared artifacts (see `project_staging.bzl`)
and analyzed via the compiled `analyze_runner` tool — no shell, no mktemp.
External (pub) dep sources sit in sibling `extpkgs` trees outside the analyzed
directory: their `package:` imports resolve, but they are not themselves
analyzed (pub packages aren't held to this target's `--fatal-infos` bar).
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "collect_packages")
load("//dart/private:project_staging.bzl", "stage_dart_project")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _pubspec_stub(packages):
    """Builds the `pubspec.yaml` the staged project is analyzed against.

    The analyzer resolves imports through `package_config.json`, never through
    this file — but lint rules read it, so it has to be a *valid* pubspec, not
    just a parseable one. A placeholder name trips `package_names`, and every
    cross-package import trips `depend_on_referenced_packages` unless the
    package is listed here. Both fire on the harness rather than on the code
    under analysis, so a strict ruleset would blame the user for rules_dart's
    staging. Dependencies are sorted because `sort_pub_dependencies` would be
    the next one.

    Constraints are `any`: nothing resolves them, and a real constraint here
    would be a second place to keep a version in sync.
    """
    lines = ["name: analyze_stub", "environment:", '  sdk: ">=3.0.0 <4.0.0"']
    names = sorted([p.package_name for p in packages if p.package_name])
    if names:
        lines.append("dependencies:")
        for name in names:
            lines.append("  %s: any" % name)
    return "\n".join(lines) + "\n"

def _dart_analyze_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    lib_info = ctx.attr.lib[DartInfo]
    packages = collect_packages([ctx.attr.lib])

    # Resources are staged beside the sources because the analyzer reads some of
    # them. `package:sky_engine`'s `lib/_embedder.yaml` is the whole of how it
    # resolves `dart:ui`, and it finds that file only by following the
    # package_config to the package root. Staged is not analyzed: external
    # packages land in the sibling `extpkgs` trees, outside the analyzed
    # directory, exactly as their sources do.
    staged = stage_dart_project(
        ctx,
        packages,
        lib_info.transitive_srcs.to_list() + lib_info.transitive_resources.to_list(),
        extra_proj_files = {"pubspec.yaml": _pubspec_stub(packages)},
    )

    inputs = list(staged.inputs)
    if ctx.attr.options:
        # The analyzer discovers analysis_options.yaml from the project root.
        options = ctx.actions.declare_file(ctx.label.name + ".proj/analysis_options.yaml")
        ctx.actions.symlink(output = options, target_file = ctx.file.options)
        inputs.append(options)

    stamp = ctx.actions.declare_file(ctx.label.name + ".analyzed")

    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    args.add("--project", staged.proj_path)
    args.add("--stamp", stamp)
    args.add("--fatal-infos")

    # Mirror dart_compile.bzl's writable-home handling (Windows dart.exe
    # receives /tmp literally and crashes).
    if dart_sdk_info.dart.basename.endswith(".exe"):
        env = {
            "USERPROFILE": stamp.dirname,
            "LOCALAPPDATA": stamp.dirname,
        }
    else:
        env = {"HOME": "/tmp"}

    ctx.actions.run(
        executable = ctx.executable._analyze_tool,
        arguments = [args],
        inputs = depset(
            direct = inputs + [dart_sdk_info.dart],
            transitive = [dart_sdk_info.tool_files],
        ),
        outputs = [stamp],
        mnemonic = "DartAnalyze",
        progress_message = "Analyzing Dart library %s" % ctx.label,
        env = env,
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
        "_analyze_tool": attr.label(
            default = "//dart/private/tools:analyze_runner",
            executable = True,
            cfg = "exec",
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:noop",
            executable = True,
            cfg = "exec",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    test = True,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Runs `dart analyze` on a Dart library as a build-time action. Fails the build if any analysis issues are found.",
)
