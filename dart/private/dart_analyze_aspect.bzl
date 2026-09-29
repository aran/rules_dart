"""The `dart_analyze` aspect: `dart analyze` and `dart fix` over one staged project.

Applied from the command line, in `.bazelrc`:

    test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
    test --output_groups=+dart_analyze
    common --@rules_dart//dart:analysis_config=//:analysis_config

it analyzes each Dart target named on the command line (it does not propagate
along `deps`), and only that target's *own* files: its `DefaultInfo` `.dart`
files plus its `DartAnalyzableInfo.srcs`. Its in-repository dependencies are
staged so their imports resolve and excluded so they are not re-checked — each
is checked when it is itself a target of the build. Targets in other
repositories (pub packages, other Bazel modules) are never checked here: the
module that owns them checks them under its own options. Generated files
(anything not `is_source`) are never checked, and the `no-dart-analyze` tag
opts a target out of the check (its fixes stay available to `dart_fix`).

Options come from the `dart_analysis_config` the `analysis_config` flag names.
Every `analysis_options.yaml` it lists is staged at its real workspace path,
and the SDK's own rule picks the nearest one for each file — exactly what the
IDE does with the same tree. Nothing on the Bazel side decides which options
govern which file.

The same staged project also feeds a `dart fix` action whose products sit in
the `dart_fix_fixes` and `dart_fix_manifest` output groups, built only when
asked for. `dart_fix` applies the aspect to its `target` and writes those
products into the workspace, so a fix and the analysis it answers can never see
different projects.
"""

load("//dart:providers.bzl", "DartAnalysisOptionsInfo", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:common.bzl", "merge_package_records", "writable_home_env")
load("//dart/private:project_staging.bzl", "pubspec_stub", "stage_dart_project", "staged_pubspec_paths")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

# Analysis and formatting run on the build machine and produce nothing for the
# target, so the SDK is chosen by the execution platform alone — the type the
# codegen rules use, for the same reason. With the target-platform type, a
# target that transitions to a platform no Dart SDK is registered for (an
# Android bundle, say) failed toolchain resolution before the aspect could even
# see it was not Dart.
_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

_OPTIONS_BASENAME = "analysis_options.yaml"

# A target carrying this tag is not checked; `dart_fix` can still fix it.
NO_ANALYZE_TAG = "no-dart-analyze"

DartAnalysisConfigInfo = provider(
    doc = "Every `analysis_options.yaml` in a repository, for the `dart_analyze` aspect.",
    fields = {
        "options_files": "list[File]: every listed `analysis_options.yaml`, staged at its workspace path.",
        "packages": "list[DartPackageInfo]: packages the listed files `include:` by `package:` URI.",
        "files": "list[File]: those packages' sources and resources, staged for resolution only.",
    },
)

DartFixOutputsInfo = provider(
    doc = "The `dart fix` products the `dart_analyze` aspect computed for one target.",
    fields = {
        "fixes": "File: directory of changed files at their workspace-relative paths.",
        "manifest": "File: JSON naming the fixed files and any discarded changes.",
    },
)

def _dart_analysis_config_impl(ctx):
    options_files = []
    packages = []
    files = []
    seen = {}
    for t in ctx.attr.options:
        opts = t[DartAnalysisOptionsInfo]
        f = opts.file

        # Options govern the files beneath them, and only this repository's
        # files are analyzed here. A shared ruleset from another module is used
        # the Dart way: `include:` it from an options file of this repository,
        # with the ruleset's package in that target's `deps`.
        if t.label.repo_name != ctx.label.repo_name or f.short_path.startswith("../"):
            fail(("%s: %s is in another repository, so the directory it would " +
                  "govern is never analyzed here. Include its ruleset from a " +
                  "`dart_analysis_options` in this repository instead.") % (ctx.label, t.label))

        # The analyzer finds options by name, walking up from each file. A file
        # named anything else would be staged and never read.
        if f.basename != _OPTIONS_BASENAME:
            fail(("%s: %s names `%s`. The analyzer only finds options files " +
                  "named `%s`, in the directory whose files they govern.") %
                 (ctx.label, t.label, f.short_path, _OPTIONS_BASENAME))
        if f.short_path in seen:
            fail("%s: `%s` is listed twice, by %s and %s." % (ctx.label, f.short_path, seen[f.short_path], t.label))
        seen[f.short_path] = t.label

        options_files.append(f)
        packages.extend(opts.packages)
        files.extend(opts.transitive_srcs.to_list() + opts.transitive_resources.to_list())

    return [DartAnalysisConfigInfo(
        options_files = options_files,
        packages = packages,
        files = files,
    )]

dart_analysis_config = rule(
    implementation = _dart_analysis_config_impl,
    attrs = {
        "options": attr.label_list(
            doc = (
                "Every `dart_analysis_options` in this repository. Each file " +
                "must be named `analysis_options.yaml`; it governs the files " +
                "below its directory up to the next listed one, as in the IDE."
            ),
            providers = [DartAnalysisOptionsInfo],
        ),
    },
    provides = [DartAnalysisConfigInfo],
    doc = (
        "Lists a repository's analysis options for the `dart_analyze` aspect " +
        "and `dart_fix`. Point `@rules_dart//dart:analysis_config` at it " +
        "under `common` in `.bazelrc`."
    ),
)

def _is_under(path, directory):
    return directory == "" or path.startswith(directory + "/")

def _wrapper_options(excluded):
    """The `analysis_options.yaml` at the staged project root.

    It governs nothing the user wrote: every checked file sits under `src/`,
    where the nearest listed options file applies (or none, meaning the SDK
    defaults). What it contributes is its `exclude` list, which the analyzer
    applies across the nested options files below it, and a stop for the
    analyzer's otherwise unbounded walk up for options.
    """
    lines = ["# rules_dart: staged project root"]
    if excluded:
        lines.append("analyzer:")
        lines.append("  exclude:")
        for path in excluded:
            lines.append('    - "%s"' % path)
    return "\n".join(lines) + "\n"

def _analyze(ctx, name, staged, sdk_inputs):
    """Declares the `dart analyze` action; returns the stamp it writes on success."""
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    stamp = ctx.actions.declare_file(name + ".analyzed")
    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    args.add("--project", staged.proj_path)
    args.add("--stamp", stamp)
    args.add("--fatal-infos")
    ctx.actions.run(
        executable = ctx.executable._analyze_tool,
        arguments = [args],
        inputs = depset(direct = staged.inputs, transitive = [sdk_inputs]),
        outputs = [stamp],
        mnemonic = "DartAnalyze",
        progress_message = "Analyzing Dart sources of %{label}",
        env = writable_home_env(dart_sdk_info.dart, stamp),
    )
    return stamp

def _dart_analyze_aspect_impl(target, ctx):
    # Checked here, not with `required_providers`: that matches only rules that
    # advertise the provider via `provides`, which dart_library and downstream
    # producers do not.
    if DartInfo not in target and DartAnalyzableInfo not in target:
        return []
    if ctx.label.repo_name:
        return []

    # A target's own files are its `DefaultInfo` Dart files — a library's
    # sources, which for a `flutter_library` are its package's `lib/` — plus an
    # executable's entrypoints, which no package can name. Generated and
    # external files are never checked.
    if DartAnalyzableInfo in target:
        info = target[DartAnalyzableInfo].dart_info
        entry = target[DartAnalyzableInfo].srcs.to_list()

        # A package's own `lib/` files, which a target's `DefaultInfo` (a web
        # bundle, a test executable) need not list. Absent from records built
        # against an older rules_dart.
        package_srcs = getattr(target[DartAnalyzableInfo], "package_srcs", depset()).to_list()
    else:
        info = target[DartInfo]
        entry = []
        package_srcs = []
    own = {}
    for f in [f for f in target[DefaultInfo].files.to_list() if f.extension == "dart"] + entry + package_srcs:
        if f.is_source and not f.short_path.startswith("../"):
            own[f.path] = f
    if not own:
        return []
    own_paths = sorted([f.short_path for f in own.values()])

    config = ctx.attr._config[DartAnalysisConfigInfo]
    packages = merge_package_records(info.transitive_packages.to_list() + config.packages)
    staged_files = (
        info.transitive_srcs.to_list() + info.transitive_resources.to_list() +
        entry + own.values() + config.files + config.options_files
    )

    # Everything else under `src/` is there to resolve against, and excluded —
    # except the options files above one of the target's own files. Their own
    # diagnostics (an `include:` that does not resolve, an unknown lint)
    # belong to every target whose files they may govern, and to no other.
    governing = {
        f.path: True
        for f in config.options_files
        if [p for p in own_paths if _is_under(p, f.short_path.rpartition("/")[0])]
    }
    excluded = {}
    for f in staged_files:
        if f.short_path.startswith("../") or f.path in own or f.path in governing:
            continue
        excluded["src/" + f.short_path] = True
    excluded = sorted(excluded.keys()) + staged_pubspec_paths(packages)

    name = ctx.label.name + ".dart_analyze"
    staged = stage_dart_project(
        ctx,
        packages,
        staged_files,
        extra_proj_files = {
            "pubspec.yaml": pubspec_stub(packages),
            _OPTIONS_BASENAME: _wrapper_options(excluded),
        },
        name = name,
    )

    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    sdk_inputs = depset(direct = [dart_sdk_info.dart], transitive = [dart_sdk_info.tool_files])

    groups = {}
    if NO_ANALYZE_TAG not in getattr(ctx.rule.attr, "tags", []):
        groups["dart_analyze"] = depset([_analyze(ctx, name, staged, sdk_inputs)])

    # Write-back is limited to the target's own hand-written files, decided
    # from Bazel's record of what each file is rather than from its name:
    # `dart fix`'s built-in generated-file skip matches `*.g.dart` and nothing
    # else, so a `.freezed.dart` part would otherwise be rewritten.
    eligible = ctx.actions.declare_file(name + ".eligible")
    ctx.actions.write(
        output = eligible,
        content = "".join(["src/%s\t%s\n" % (p, p) for p in own_paths]),
    )
    fixes = ctx.actions.declare_directory(name + ".fixes")
    manifest = ctx.actions.declare_file(name + ".fix_manifest.json")
    scratch = ctx.actions.declare_directory(name + ".scratch")
    fix_args = ctx.actions.args()
    fix_args.add("--dart", dart_sdk_info.dart)
    fix_args.add("--project", staged.proj_path)
    fix_args.add("--scratch", scratch.path)
    fix_args.add("--fixes", fixes.path)
    fix_args.add("--manifest", manifest)
    fix_args.add("--eligible", eligible)
    ctx.actions.run(
        executable = ctx.executable._fix_tool,
        arguments = [fix_args],
        inputs = depset(direct = staged.inputs + [eligible], transitive = [sdk_inputs]),
        outputs = [fixes, manifest, scratch],
        mnemonic = "DartFix",
        progress_message = "Computing Dart fixes for %{label}",
        env = writable_home_env(dart_sdk_info.dart, manifest),
    )

    return [
        OutputGroupInfo(
            dart_fix_fixes = depset([fixes]),
            dart_fix_manifest = depset([manifest]),
            **groups
        ),
        DartFixOutputsInfo(fixes = fixes, manifest = manifest),
    ]

dart_analyze = aspect(
    implementation = _dart_analyze_aspect_impl,
    attrs = {
        "_config": attr.label(
            default = "//dart:analysis_config",
            providers = [DartAnalysisConfigInfo],
        ),
        "_analyze_tool": attr.label(
            default = "//dart/private/tools:analyze_runner",
            executable = True,
            cfg = "exec",
        ),
        "_fix_tool": attr.label(
            default = "//dart/private/tools:fix_runner",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Runs `dart analyze` on a Dart target's own files; see `@rules_dart//dart:analyze.bzl`.",
)
