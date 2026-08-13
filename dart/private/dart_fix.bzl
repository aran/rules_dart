"""Implementation of the dart_fix rule.

`dart fix --apply` is the analyzer's automated-fix pass — the quick-fixes an IDE
offers, driven by whatever lints `analysis_options.yaml` enables. Running it
under Bazel is awkward for one reason: it edits sources in place, and a build
action may only write to declared outputs inside a sandbox whose inputs are
read-only.

So the work splits in two. A build action computes the fixes hermetically —
staging the project exactly as `dart_analyze_test` does, fixing a scratch copy,
and emitting *only the changed files* plus a manifest — and the rule's
executable copies those files into the source tree under `bazel run`. That is
the same shape as `//tools:preset.update` and buildifier's check/fix split, and
it means the fixes are always computed from the sources currently on disk:
`bazel run` rebuilds the action first.

Generated files are protected twice over. A synthesized wrapper options file
excludes every staged non-source file, so the analyzer resolves them (a
hand-written library that `part`s its `.g.dart` does not analyze without it) but
proposes no fixes for them. And independently, only files that were `is_source`
at analysis time are ever eligible for write-back. The second is the guarantee;
the first only keeps `dart fix` from wasting passes on files it must not touch.
Both are needed because `dart fix`'s own built-in generated-file skip matches
`*.g.dart` and nothing else — a `.freezed.dart` part gets rewritten.
"""

load("//dart:providers.bzl", "DartAnalysisOptionsInfo", "DartInfo")
load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "collect_packages", "merge_package_records")
load("//dart/private:project_staging.bzl", "pubspec_stub", "stage_dart_project")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _wrapper_options(has_user_options, excluded):
    """The `analysis_options.yaml` written at the staged project root.

    Composes rather than edits: the user's file may be an opaque `include:`
    chain ending in a published ruleset, so the only safe way to add exclusions
    is to include it from a file we own. Lint rules from the included file still
    fire and the two `exclude` lists union.
    """
    lines = []
    if has_user_options:
        lines.append("include: analysis_options.user.yaml")
    if excluded:
        lines.append("analyzer:")
        lines.append("  exclude:")
        for path in excluded:
            lines.append('    - "%s"' % path)
    return "\n".join(lines) + "\n" if lines else "\n"

def _dart_fix_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    lib_info = ctx.attr.lib[DartInfo]
    packages = collect_packages([ctx.attr.lib])

    # Same as `dart_analyze_test`: an options target may carry the packages its
    # `include:` directives resolve against. They are staged for resolution
    # only and never enter the analyzed library's own provider.
    options_files = []
    if ctx.attr.options and DartAnalysisOptionsInfo in ctx.attr.options:
        opts = ctx.attr.options[DartAnalysisOptionsInfo]
        packages = merge_package_records(packages + opts.packages)
        options_files = (
            opts.transitive_srcs.to_list() + opts.transitive_resources.to_list()
        )

    staged_files = (
        lib_info.transitive_srcs.to_list() +
        lib_info.transitive_resources.to_list() + options_files
    )

    # Eligibility is decided here, at analysis time, from Bazel's own record of
    # what a file is — not from its name. `is_source` is false for anything a
    # rule generated, which is exactly the set no one may hand-edit, and the
    # `../` test drops external repositories, which are not ours to rewrite.
    eligible = []
    excluded = []
    for f in staged_files:
        if f.short_path.startswith("../"):
            continue
        staged_path = "src/" + f.short_path
        if f.is_source:
            eligible.append((staged_path, f.short_path))
        else:
            excluded.append(staged_path)

    staged = stage_dart_project(
        ctx,
        packages,
        staged_files,
        extra_proj_files = {
            # The same stub `dart_analyze_test` stages. Without it the two rules
            # analyze different projects, and any pubspec-reading lint reports in
            # analyze while `dart fix` never proposes its fix — breaking the
            # invariant that sharing `options` makes `bazel run` turn the analyze
            # test green.
            "pubspec.yaml": pubspec_stub(packages),
            "analysis_options.yaml": _wrapper_options(
                ctx.attr.options != None,
                sorted(excluded),
            ),
        },
    )

    inputs = list(staged.inputs)
    if ctx.attr.options:
        # Included by the wrapper above rather than used directly, so the
        # wrapper's exclusions survive whatever the user's file sets.
        user_options = ctx.actions.declare_file(
            ctx.label.name + ".proj/analysis_options.user.yaml",
        )
        ctx.actions.symlink(output = user_options, target_file = ctx.file.options)
        inputs.append(user_options)

    eligible_list = ctx.actions.declare_file(ctx.label.name + ".eligible")
    ctx.actions.write(
        output = eligible_list,
        content = "".join([
            "%s\t%s\n" % (staged_path, workspace_path)
            for staged_path, workspace_path in sorted(eligible)
        ]),
    )
    inputs.append(eligible_list)

    fixes = ctx.actions.declare_directory(ctx.label.name + ".fixes")
    manifest = ctx.actions.declare_file(ctx.label.name + ".fix_manifest.json")
    scratch = ctx.actions.declare_directory(ctx.label.name + ".scratch")

    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    args.add("--project", staged.proj_path)
    args.add("--scratch", scratch.path)
    args.add("--fixes", fixes.path)
    args.add("--manifest", manifest)
    args.add("--eligible", eligible_list)

    # Mirrors dart_analyze.bzl: Windows `dart.exe` takes `/tmp` literally.
    if dart_sdk_info.dart.basename.endswith(".exe"):
        env = {"USERPROFILE": manifest.dirname, "LOCALAPPDATA": manifest.dirname}
    else:
        env = {"HOME": "/tmp"}

    ctx.actions.run(
        executable = ctx.executable._fix_runner,
        arguments = [args],
        inputs = depset(
            direct = inputs + [dart_sdk_info.dart],
            transitive = [dart_sdk_info.tool_files],
        ),
        outputs = [fixes, manifest, scratch],
        mnemonic = "DartFix",
        progress_message = "Computing Dart fixes for %s" % ctx.label,
        env = env,
    )

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._fix_applier,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [fixes, manifest])
    runfiles = runfiles.merge(ctx.attr._fix_applier[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        # `bazel run //pkg:fix -- --dry-run` forwards only the user's arguments,
        # so the applier learns where its inputs are through the environment
        # rather than through a shell wrapper this repo would have to keep
        # working on Windows.
        RunEnvironmentInfo(environment = {
            "DART_FIX_FIXES": fixes.short_path,
            "DART_FIX_MANIFEST": manifest.short_path,
        }),
    ]

dart_fix = rule(
    implementation = _dart_fix_impl,
    attrs = dict({
        "lib": attr.label(
            doc = "The `dart_library` target to fix. Its whole transitive closure is considered, matching `dart_analyze_test`.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "options": attr.label(
            doc = (
                "A `dart_analysis_options` target, or a bare " +
                "`analysis_options.yaml`. Should be the same target the " +
                "matching `dart_analyze_test` uses: fixes are driven by the " +
                "lints that are enabled, so differing options mean `bazel run` " +
                "cannot turn the analyze test green."
            ),
            allow_single_file = [".yaml"],
        ),
        "_fix_runner": attr.label(
            default = "//dart/private/tools:fix_runner",
            executable = True,
            cfg = "exec",
        ),
        "_fix_applier": attr.label(
            default = "//dart/private/tools:fix_applier",
            executable = True,
            cfg = "target",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    executable = True,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = (
        "Applies `dart fix` to a Dart library's sources. `bazel run` writes " +
        "the fixes into the workspace; `bazel run ... -- --dry-run` prints " +
        "them instead. Generated files are never written."
    ),
)
