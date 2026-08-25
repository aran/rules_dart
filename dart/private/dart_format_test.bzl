"""Implementation of the dart_format_test rule.

Checks `dart format` as a build-time action, in the same shape as
`dart_analyze_test`: the verdict is computed while building a stamp file, and
the test target is a pass-through that always succeeds.

A build action rather than a test is what makes the check mean anything. The
formatter reads its configuration — `page_width`, `trailing_commas` — from the
`formatter:` section of an `analysis_options.yaml`, which it discovers by an
unbounded lexical walk up from each file it is given, without resolving
symlinks. Handed runfiles paths, that walk found no options file at all under a
sandbox (so a repo's configured page width was silently ignored) and climbed
into the execroot or straight into the source tree without one (so the verdict
depended on the spawn strategy, and the formatter read files no action had
declared). Staging a project directory and running over it puts every ancestor
the walk can reach under Bazel's control — see `stage_root_options`, which is
what terminates it.

The staged project is deliberately thinner than the analyzer's: formatting is
purely syntactic, so no import has to resolve. Only an options file that
`include`s a ruleset by `package:` URI needs a `package_config.json`, and that
is exactly what `dart_analysis_options` carries. No project-root `pubspec.yaml`
is written either, as `dart_analyze_test` writes one: the formatter takes the
language version that selects its style from `package_config.json` alone, never
from a pubspec's `sdk:` constraint (measured on Dart 3.12.2 across `any`,
`^3.6.0`, `>=3.0.0 <4.0.0` and `^3.12.0` — all four formatted identically), so a
pubspec is a measured non-input here. The per-package stub pubspecs
`stage_dart_project` writes still appear, but only for the packages it is
handed — here the options target's `deps`, never the formatted sources — and
the formatter's options walk-up does not stop at a pubspec (measured on Dart
3.12.2), so one above a formatted file changes no verdict.
"""

load(
    "//dart/private:common.bzl",
    "WINDOWS_CONSTRAINT_ATTR",
    "analysis_options_closure",
    "noop_test_executable",
    "writable_home_env",
)
load("//dart/private:project_staging.bzl", "stage_dart_project", "stage_root_options")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _dart_format_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # An options file may `include:` a ruleset by `package:` URI, which the
    # formatter resolves through the staged `package_config.json` exactly as
    # the analyzer does. Those packages are staged so that resolution works and
    # for nothing else — they are never themselves formatted, because the
    # manifest below names only this target's own sources.
    opts = analysis_options_closure(ctx.attr.options)

    # External sources are refused rather than staged. `stage_dart_project`
    # keeps an external file only when it belongs to a known external package,
    # and a loose `.dart` file from another repo matches none — it would be
    # dropped from the staged tree, leaving the manifest naming a path that
    # does not exist. Failing here instead is also the honest answer to what
    # the check could mean: a formatting violation in a module you do not own
    # is a red build with no edit in this repo that can turn it green.
    for src in ctx.files.srcs:
        if src.short_path.startswith("../"):
            fail(
                ("dart_format_test cannot format sources from external " +
                 "repositories: {}. Declare a dart_format_test in the " +
                 "module that owns the file instead.").format(src.short_path),
            )

    staged = stage_dart_project(
        ctx,
        opts.packages,
        ctx.files.srcs + opts.files,
    )

    # The one file that stops the formatter's walk-up inside the staged tree.
    options_file = stage_root_options(ctx, ctx.file.options)

    # Files are named individually rather than by handing the formatter the
    # project directory: the staged tree also holds the package_config and, for
    # a `package:` include, the ruleset package's own sources, none of which
    # are this target's to format.
    manifest = ctx.actions.declare_file(ctx.label.name + ".format_manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join([
            "src/%s\n" % src.short_path
            for src in ctx.files.srcs
        ]),
    )

    stamp = ctx.actions.declare_file(ctx.label.name + ".formatted")

    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    args.add("--project", staged.proj_path)
    args.add("--manifest", manifest)
    args.add("--stamp", stamp)

    ctx.actions.run(
        executable = ctx.executable._format_runner,
        arguments = [args],
        inputs = depset(
            direct = list(staged.inputs) + [
                options_file,
                manifest,
                dart_sdk_info.dart,
            ],
            transitive = [dart_sdk_info.tool_files],
        ),
        outputs = [stamp],
        mnemonic = "DartFormat",
        progress_message = "Checking Dart formatting of %s" % ctx.label,
        env = writable_home_env(dart_sdk_info.dart, stamp),
    )

    noop = noop_test_executable(ctx, ctx.attr._tool)
    return [DefaultInfo(
        executable = noop.executable,
        runfiles = ctx.runfiles(files = [stamp]).merge(noop.runfiles),
    )]

dart_format_test = rule(
    implementation = _dart_format_test_impl,
    attrs = dict({
        "srcs": attr.label_list(
            doc = (
                "Dart source files (`.dart`) to check. Typically " +
                "`glob([\"lib/**/*.dart\"])`. Files from external " +
                "repositories are rejected."
            ),
            allow_files = [".dart"],
            mandatory = True,
        ),
        "options": attr.label(
            doc = (
                "A `dart_analysis_options` target, or a bare " +
                "`analysis_options.yaml`. Its `formatter:` section — " +
                "`page_width`, `trailing_commas` — governs the check. Use " +
                "the target form when the file `include`s a ruleset by " +
                "`package:` URI. If omitted, stock `dart format` defaults " +
                "apply, and are pinned hermetically rather than left to " +
                "whatever file happens to sit above the sources."
            ),
            allow_single_file = [".yaml"],
        ),
        "_format_runner": attr.label(
            default = "//dart/private/tools:format_runner",
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
    doc = (
        "Checks that Dart source files match `dart format` output, as a " +
        "build-time action. Fails the build if any file would be changed by " +
        "formatting."
    ),
)
