"""Implementation of the dart_fix rule.

`dart fix --apply` is the analyzer's automated-fix pass — the quick-fixes an IDE
offers, driven by whatever lints the analysis options enable. Running it under
Bazel is awkward for one reason: it edits sources in place, and a build action
may only write to declared outputs inside a sandbox whose inputs are read-only.

So the work splits in two. The `dart_analyze` aspect computes the fixes
hermetically, over the very project it stages to analyze the target, and emits
*only the changed files* plus a manifest. This rule applies that aspect to its
`target` and hands those products to an executable that copies them into the
source tree under `bazel run`. The fixes are always computed from the sources on
disk (`bazel run` rebuilds first), under the options `//dart:analysis_config`
names — the same ones the aspect analyzes with, which is what lets a run turn a
red analysis green.

Only the target's own hand-written files are ever written: the aspect's
eligibility list is decided from Bazel's record of what each file is
(`is_source`), not from its name.
"""

load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR")
load("//dart/private:dart_analyze_aspect.bzl", "DartFixOutputsInfo", "dart_analyze")

def _dart_fix_impl(ctx):
    target = ctx.attr.target
    if DartFixOutputsInfo not in target:
        fail(("%s: %s has nothing to fix — it is in another repository, or " +
              "has no hand-written Dart files of its own.") % (ctx.label, target.label))
    outputs = target[DartFixOutputsInfo]

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._fix_applier,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [outputs.fixes, outputs.manifest])
    runfiles = runfiles.merge(ctx.attr._fix_applier[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        # Neither product is a predeclared output, so neither has a label of its
        # own. These groups are how a BUILD file names them —
        # `filegroup(srcs = [":fix"], output_group = ...)` — and how
        # `--output_groups=+dart_fix_manifest` materialises one from the command
        # line without running a tool that rewrites sources. Two singleton
        # groups, because `$(execpath)` and `allow_single_file` both reject a
        # label that expands to more than one file.
        OutputGroupInfo(
            dart_fix_fixes = depset([outputs.fixes]),
            dart_fix_manifest = depset([outputs.manifest]),
        ),
        # `bazel run //pkg:fix -- --dry-run` forwards only the user's arguments,
        # so the applier learns where its inputs are through the environment
        # rather than through a shell wrapper this repo would have to keep
        # working on Windows.
        RunEnvironmentInfo(environment = {
            "DART_FIX_FIXES": outputs.fixes.short_path,
            "DART_FIX_MANIFEST": outputs.manifest.short_path,
        }),
    ]

dart_fix = rule(
    implementation = _dart_fix_impl,
    attrs = dict({
        "target": attr.label(
            doc = (
                "The target whose Dart sources to fix — a `dart_library`, or a " +
                "`dart_binary`/`dart_test`/web binary. Only its own " +
                "hand-written files are fixed: the files the `dart_analyze` " +
                "aspect checks for it."
            ),
            mandatory = True,
            aspects = [dart_analyze],
        ),
        "_fix_applier": attr.label(
            default = "//dart/private/tools:fix_applier",
            executable = True,
            cfg = "target",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    executable = True,
    doc = (
        "Applies `dart fix` to a Dart target's own sources, under the options " +
        "`@rules_dart//dart:analysis_config` names. `bazel run` writes the " +
        "fixes into the workspace; `bazel run ... -- --dry-run` prints them " +
        "instead. Generated files are never written.\n" +
        "\n" +
        "Output Groups:\n" +
        "  dart_fix_fixes: A directory of the changed files, at their " +
        "workspace-relative paths.\n" +
        "  dart_fix_manifest: JSON recording which files were fixed and " +
        "which changes were discarded as ineligible.\n" +
        "\n" +
        "Build either directly to inspect what a run would do without " +
        "rewriting anything, e.g. " +
        "`bazel build //pkg:fix --output_groups=+dart_fix_manifest`."
    ),
)
