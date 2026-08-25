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

The language version is passed on the command line, never inferred. It selects
the formatting *style* — below 3.7 `dart format` emits the old short style,
from 3.7 on the tall one — and the formatter takes it from a
`package_config.json` entry covering the file, falling back to the newest
version the SDK knows when no entry claims it. The staged config never has an
entry for the files this rule formats: they arrive as loose `srcs`, or as the
sources of one `dart_library`, and neither is a package the project has to
resolve. Left inferred, then, every check would run at the SDK's newest version
whatever the code declares, and a package below 3.7 would be told to adopt a
style its own `dart format` will never produce — a red build no edit can fix.
`--language-version` settles it from the target instead: `dart_library`'s
`language_version` when `target` names one, this rule's own when it is handed
loose `srcs`, and `latest` when neither says. Passing it even in that last case
is deliberate; it keeps the verdict off the staged config, which an options
target's own package deps do write into.
"""

load("//dart:providers.bzl", "DartInfo")
load(
    "//dart/private:common.bzl",
    "WINDOWS_CONSTRAINT_ATTR",
    "analysis_options_closure",
    "noop_test_executable",
    "own_package_record",
    "writable_home_env",
)
load("//dart/private:project_staging.bzl", "stage_dart_project", "stage_root_options")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _format_operand(ctx):
    """Resolves `srcs`/`target` to the files to format and their language version.

    The two forms differ in where the language version can come from, and that
    is the whole reason they are told apart here. A `dart_library` already
    declares one, so taking a second answer from this rule could only introduce
    a way for the two to disagree — hence the `fail` rather than a precedence
    rule. Loose `srcs` belong to no target that could declare it, so for them
    the attribute is the only channel there is.

    Args:
      ctx: The rule context.

    Returns:
      `struct(srcs, language_version)` — the files to format, and the version
      to format them at (empty when nothing declares one).
    """
    if ctx.attr.target and ctx.files.srcs:
        fail(
            ("%s: set either `srcs` or `target`, not both. `target` formats " +
             "the sources of one `dart_library`; `srcs` formats a list of " +
             "files.") % ctx.label,
        )
    if not ctx.attr.target and not ctx.files.srcs:
        fail(
            ("%s: set `target` (a `dart_library` whose sources to format) or " +
             "`srcs` (the files to format).") % ctx.label,
        )

    if not ctx.attr.target:
        return struct(
            srcs = ctx.files.srcs,
            language_version = ctx.attr.language_version,
        )

    if ctx.attr.language_version:
        fail(
            ("%s: `language_version` cannot be set alongside `target`. The " +
             "version is the library's to declare — set " +
             "`language_version` on %s instead.") % (
                ctx.label,
                ctx.attr.target.label,
            ),
        )

    # A library's own files, not its closure: `DefaultInfo` carries exactly the
    # sources and resources it declared, where `DartInfo.transitive_srcs` would
    # sweep in every dependency's. Formatting is a claim about code you own.
    own_files = ctx.attr.target[DefaultInfo].files.to_list()
    for f in own_files:
        if f.is_directory:
            fail(
                ("%s: `target` %s is backed by `srcs_dir`, whose contents are " +
                 "one opaque directory. `dart_format_test` names each file it " +
                 "formats, and the members of a tree artifact are not known " +
                 "when that list is built.") % (ctx.label, ctx.attr.target.label),
            )
    srcs = [f for f in own_files if f.extension == "dart"]
    if not srcs:
        fail(
            ("%s: `target` %s declares no Dart sources of its own — a " +
             "deps-only facade has nothing to format, and a check over no " +
             "files would pass without looking at anything.") % (
                ctx.label,
                ctx.attr.target.label,
            ),
        )

    pkg = own_package_record(ctx.attr.target[DartInfo])
    return struct(
        srcs = srcs,
        language_version = pkg.language_version if pkg else "",
    )

def _dart_format_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # An options file may `include:` a ruleset by `package:` URI, which the
    # formatter resolves through the staged `package_config.json` exactly as
    # the analyzer does. Those packages are staged so that resolution works and
    # for nothing else — they are never themselves formatted, because the
    # manifest below names only this target's own sources.
    opts = analysis_options_closure(ctx.attr.options)
    operand = _format_operand(ctx)

    # External sources are refused rather than staged. `stage_dart_project`
    # keeps an external file only when it belongs to a known external package,
    # and a loose `.dart` file from another repo matches none — it would be
    # dropped from the staged tree, leaving the manifest naming a path that
    # does not exist. Failing here instead is also the honest answer to what
    # the check could mean: a formatting violation in a module you do not own
    # is a red build with no edit in this repo that can turn it green. Checked
    # on the resolved list, so a `target` in another module is refused on the
    # same terms as a loose external file.
    for src in operand.srcs:
        if src.short_path.startswith("../"):
            fail(
                ("dart_format_test cannot format sources from external " +
                 "repositories: {}. Declare a dart_format_test in the " +
                 "module that owns the file instead.").format(src.short_path),
            )

    staged = stage_dart_project(
        ctx,
        opts.packages,
        operand.srcs + opts.files,
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
            for src in operand.srcs
        ]),
    )

    stamp = ctx.actions.declare_file(ctx.label.name + ".formatted")

    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    args.add("--project", staged.proj_path)
    args.add("--manifest", manifest)
    args.add("--stamp", stamp)

    # Always explicit — `latest` is what the formatter would have inferred with
    # nothing to go on, said out loud so no staged config can answer instead.
    args.add("--language-version", operand.language_version or "latest")

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
        "language_version": attr.string(
            doc = (
                "The Dart language version to format `srcs` at, as " +
                "`<major>.<minor>`. It selects the style — below `3.7` the " +
                "old short style, from `3.7` on the tall one — so a check " +
                "over a package that declares an older version needs it to " +
                "agree with what `dart format` does on the same files " +
                "outside Bazel. Defaults to the newest version the SDK " +
                "knows. Rejected alongside `target`, which declares its own."
            ),
        ),
        "srcs": attr.label_list(
            doc = (
                "Dart source files (`.dart`) to check. Typically " +
                "`glob([\"lib/**/*.dart\"])`. Files from external " +
                "repositories are rejected. Set this or `target`, not both."
            ),
            allow_files = [".dart"],
        ),
        "target": attr.label(
            doc = (
                "A `dart_library` whose own sources to check — the files it " +
                "declares, never its dependencies'. Preferred over `srcs` " +
                "when the files are already a library: the language version " +
                "comes with it, so the check and the library cannot drift " +
                "apart. Set this or `srcs`, not both."
            ),
            providers = [DartInfo],
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
