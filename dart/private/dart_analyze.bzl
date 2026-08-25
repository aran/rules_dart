"""Implementation of the dart_analyze_test rule.

Runs `dart analyze` on a Dart target as a Bazel test. The analysis runs at build
time as an action — if analysis fails, the build fails. The test target itself is
a trivial pass-through that always succeeds.

The operand is a `dart_library` or an executable (`dart_binary`, `dart_test`, a
web binary). An executable's entrypoint belongs to no package's `lib/`, so it
reaches this rule through `DartAnalyzableInfo` rather than `DartInfo` — see that
provider for why an executable does not simply hand out the latter.

The analyzer wants a project directory (pubspec.yaml, .dart_tool/, sources),
which is staged hermetically from declared artifacts (see `project_staging.bzl`)
and analyzed via the compiled `analyze_runner` tool — no shell, no mktemp.
External (pub) dep sources sit in sibling `extpkgs` trees outside the analyzed
directory: their `package:` imports resolve, but they are not themselves
analyzed (pub packages aren't held to this target's `--fatal-infos` bar).
"""

load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load(
    "//dart/private:common.bzl",
    "WINDOWS_CONSTRAINT_ATTR",
    "analysis_options_closure",
    "analyzable_closure",
    "analyze_operand",
    "merge_package_records",
)
load("//dart/private:project_staging.bzl", "pubspec_stub", "stage_dart_project", "stage_root_options")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _dart_analyze_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    closure = analyzable_closure(analyze_operand(ctx))
    lib_info = closure.dart_info
    packages = merge_package_records(lib_info.transitive_packages.to_list())

    # An options file may `include:` a ruleset by `package:` URI, which resolves
    # through this project's package_config like any import. Those packages are
    # staged for that resolution only: they join `packages` (so package_config
    # names them) and the staged file list, but come from the options target
    # rather than from the analyzed target, so they never enter its own
    # `DartInfo`. Every one of them is external, so `stage_dart_project` files
    # them under `extpkgs` — resolvable, not analyzed.
    opts = analysis_options_closure(ctx.attr.options)
    packages = merge_package_records(packages + opts.packages)
    options_files = opts.files

    # Resources are staged beside the sources because the analyzer reads some of
    # them. `package:sky_engine`'s `lib/_embedder.yaml` is the whole of how it
    # resolves `dart:ui`, and it finds that file only by following the
    # package_config to the package root. Staged is not analyzed: external
    # packages land in the sibling `extpkgs` trees, outside the analyzed
    # directory, exactly as their sources do.
    #
    # `closure.srcs` is empty for a library and holds the entrypoint for an
    # executable: a `main` belongs to no package's `lib/`, so nothing in
    # `transitive_srcs` can name it and it would otherwise never be staged.
    staged = stage_dart_project(
        ctx,
        packages,
        lib_info.transitive_srcs.to_list() +
        lib_info.transitive_resources.to_list() + closure.srcs + options_files,
        extra_proj_files = {"pubspec.yaml": pubspec_stub(packages)},
    )

    # Unconditional: an options file at the project root is what bounds the
    # analyzer's discovery walk, so the no-options case needs one just as much
    # as the configured case — see `stage_root_options`.
    inputs = list(staged.inputs) + [stage_root_options(ctx, ctx.file.options)]

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
        progress_message = "Analyzing Dart sources of %s" % ctx.label,
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
            doc = "Deprecated alias for `target`. Set one or the other, never both.",
            providers = [[DartInfo], [DartAnalyzableInfo]],
        ),
        "options": attr.label(
            doc = "An `analysis_options.yaml` file. If omitted, the Dart SDK's default analysis options are used.",
            allow_single_file = [".yaml"],
        ),
        "target": attr.label(
            doc = (
                "The target whose Dart sources to analyze — a `dart_library`, " +
                "or a `dart_binary`/`dart_test`/web binary, whose entrypoint " +
                "is analyzed along with its whole transitive closure."
            ),
            providers = [[DartInfo], [DartAnalyzableInfo]],
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
    doc = "Runs `dart analyze` on a Dart target as a build-time action. Fails the build if any analysis issues are found.",
)
