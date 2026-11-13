"""The `dart_analyze` aspect: `dart analyze`, `dart format` and `dart fix` over one staged project.

Applied from the command line, in `.bazelrc`:

    test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
    test --output_groups=+dart_analyze
    test --output_groups=+dart_format
    common --@rules_dart//dart:analysis_config=//:analysis_config

it checks each Dart target named on the command line (it does not propagate
along `deps`), and only that target's *own* files: its `DefaultInfo` `.dart`
files plus its `DartAnalyzableInfo.entry_srcs`. Each check is its own output group
and its own actions — `dart_analyze` for the analyzer, `dart_format` for the
format check — so a project runs whichever of the two its `--output_groups`
names, and only that one. Its in-repository dependencies are never re-checked
here — each is checked when it is itself a target of the build: under
`analysis_summaries` (the default) their imports resolve through the
dependencies' analyzer summaries and only the target's own files are staged;
with it off they are staged so their imports resolve, and excluded. Targets
in other repositories (pub packages, other Bazel modules) are never checked
here: the module that owns them checks them under its own options. Generated files
(anything not `is_source`) are never checked. The `no-dart-analyze` tag opts a
target out of analysis (its fixes stay available to
`@rules_dart//dart/fix`), and `no-dart-format` out of the format check and its
rewrites; each leaves the other in place.

Options come from the `dart_analysis_config` the `analysis_config` flag names.
Every `analysis_options.yaml` it lists is staged at its real workspace path,
and the SDK's own rule picks the nearest one for each file — exactly what the
IDE does with the same tree. Nothing on the Bazel side decides which options
govern which file. A relative `include:` resolves against the staged copy, so
it can only reach what is staged; the one way to share a yaml that governs no
directory is a `package:` include of a package in the options target's `deps`.
The formatter finds its `formatter:` section by the same walk, so both checks
read one file's options from the same place.

The format check names the target's own files individually and passes the
language version of the target's own package on the command line. That version
selects the formatting style (below 3.7 the old short one), and passing it
keeps the verdict off whatever `package_config.json` entry happens to cover a
staged file — an entrypoint outside `lib/`, say. An executable that states no
package of its own takes the version of the in-repo package whose root contains
its entrypoint, and one containing no such package is formatted at `latest`, as
`dart format` would with nothing to go on.

The format check is two actions. The first runs the formatter and records
what it would change, with the new content, in a changes file
(`changes.dart`), the `dart_format_changes` output group; the second fails when
that file proposes anything, and its stamp is the `dart_format` group. `bazel
run @rules_dart//dart/format` builds `dart_format_changes` over target patterns
and writes it into the workspace, so the check and the rewrite are one
computation and cannot disagree.

The analyzer's staged project also feeds a `dart fix` action whose changes
file is the `dart_fix_changes` group, built only when asked for; `bazel run
@rules_dart//dart/fix` writes it, so a fix and the analysis it answers can
never see different projects.

`dart_analysis_test` applies this aspect to targets a wildcard cannot reach.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartAnalysisOptionsInfo", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:common.bzl", "PATH_MAPPING", "SDK_ENV", "default_language_version", "merge_package_records", "own_packages")
load("//dart/private:dart_info.bzl", "analyzed_closure")
load("//dart/private:dart_summary.bzl", "DartSummaryAnalyzerInfo", "SUMMARIES_FLAG", "summary_analyzer_action")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_sdk")
load("//dart/private:project_staging.bzl", "project_layout", "pubspec_stub", "stage_dart_project", "staged_pubspec_paths")
load("//dart/private:resources.bzl", "source_analysis_resources")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

visibility("//dart/...")

# Analysis and formatting run on the build machine and produce nothing for the
# target, so they run in `PORTABLE`, whose SDK is chosen by the execution
# platform alone, as the codegen rules' is. With the target-platform type, a
# target that transitions to a platform no Dart SDK is registered for (an
# Android bundle, say) failed toolchain resolution before the aspect could even
# see it was not Dart.

_OPTIONS_BASENAME = "analysis_options.yaml"

# A target carrying this tag is not analyzed; `@rules_dart//dart/fix` can
# still fix it.
NO_ANALYZE_TAG = "no-dart-analyze"

# A target carrying this tag is not format-checked or formatted; analysis is
# unaffected.
NO_FORMAT_TAG = "no-dart-format"

DartAnalysisConfigInfo = provider(
    doc = "Every `analysis_options.yaml` in a repository, for the `dart_analyze` aspect.",
    fields = {
        "options_files": "list[File]: every listed `analysis_options.yaml`, staged at its workspace path.",
        "packages": "list[DartPackageInfo]: packages the listed files `include:` by `package:` URI.",
        "files": "list[File]: those packages' sources and resources, staged for resolution only.",
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
        "and the formatting and fixes it computes. Point " +
        "`@rules_dart//dart:analysis_config` at it under `common` in " +
        "`.bazelrc`."
    ),
)

def _is_under(path, directory):
    return directory == "" or path.startswith(directory + "/")

def _wrapper_options(excluded):
    """The `analysis_options.yaml` at the staged project root.

    It governs nothing the user wrote: every checked file sits under `src/`,
    where the nearest listed options file applies (or none, meaning the SDK
    defaults — it has no `formatter:` section either). What it contributes is
    its `exclude` list, which the analyzer applies across the nested options
    files below it, and a stop for the analyzer's and the formatter's otherwise
    unbounded walk up for options: without it, a file no listed options govern
    would be judged by whatever `analysis_options.yaml` sits above the staged
    project — nothing under a sandbox, the workspace's own in the execroot.
    """
    lines = ["# rules_dart: staged project root"]
    if excluded:
        lines.append("analyzer:")
        lines.append("  exclude:")
        for path in excluded:
            lines.append('    - "%s"' % path)
    return "\n".join(lines) + "\n"

def stage_config_project(ctx, config, packages, files, own, name, dart_sdk_info):
    """Stages a project holding every options file `config` lists.

    The one place a project is laid out for options to be found in: the
    `dart_analyze` aspect stages its target here for analysis, fixes and the
    format check, so none of them can see different settings for the same
    file. Every listed `analysis_options.yaml`
    sits at its workspace path under `src/`, with the packages its `include:`s
    resolve against, and the wrapper above them all ends the walk up for
    options inside the project.

    Args:
      ctx: The rule or aspect context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      config: The `DartAnalysisConfigInfo` to stage.
      packages: `DartPackageInfo` records the staged files need, besides the
        config's own.
      files: Files to stage besides the config's.
      own: The Files being checked; everything else staged is excluded from
        analysis, but for the options files above one of them.
      name: Prefix for the staged paths.
      dart_sdk_info: The toolchain's `DartSdkInfo` (see `pubspec_stub`).

    Returns:
      The `stage_dart_project` struct.
    """
    packages = merge_package_records(packages + config.packages)
    layout = project_layout(packages, files + config.files + config.options_files, own)
    own_paths = [f.short_path for f in own]
    own_set = {f.path: True for f in own}

    # Everything else under `src/` is there to resolve against, and excluded —
    # except the options files above one of the own files. Their own
    # diagnostics (an `include:` that does not resolve, an unknown lint)
    # belong to every target whose files they may govern, and to no other.
    governing = {
        f.path: True
        for f in config.options_files
        if [p for p in own_paths if _is_under(p, f.short_path.rpartition("/")[0])]
    }
    excluded = {}
    for f in layout.src_files:
        if f.path in own_set or f.path in governing:
            continue
        excluded["src/" + f.short_path] = True
    excluded = sorted(excluded.keys()) + staged_pubspec_paths(layout)

    return stage_dart_project(
        ctx,
        layout,
        dart_sdk_info,
        extra_proj_files = {
            "pubspec.yaml": pubspec_stub(packages, dart_sdk_info),
            _OPTIONS_BASENAME: _wrapper_options(excluded),
        },
        name = name,
    )

def _project_dir(src_tree):
    return src_tree.dirname

def _add_project(args, staged):
    args.add_all([staged.src_tree], before_each = "--project", map_each = _project_dir, expand_directories = False)

def _analyzer(ctx):
    """How the analyze and fix actions run their analyzer.

    Under `analysis_worker` (the default), in a persistent worker that keeps
    the analysis server, hosted by `analysis_host.dart`, across requests: the
    host is the worker's own argument, and everything else is a request's.
    Off, a fresh `dart analyze` or `dart fix` per action.

    Args:
      ctx: The aspect's context.

    Returns:
      A struct: `startup` and `request` `Args`, the `tools` to add, and the
      `execution_requirements`.
    """
    startup = ctx.actions.args()
    request = ctx.actions.args()
    if not ctx.attr._analysis_worker[BuildSettingInfo].value:
        return struct(startup = startup, request = request, tools = [], execution_requirements = PATH_MAPPING)
    startup.add("--host", ctx.file._analysis_host)
    request.use_param_file("@%s", use_always = True)
    request.set_param_file_format("multiline")
    return struct(
        startup = startup,
        request = request,
        tools = [ctx.file._analysis_host],
        execution_requirements = PATH_MAPPING | {
            "requires-worker-protocol": "proto",
            "supports-workers": "1",
        },
    )

def _analyze(ctx, name, staged, sdk_inputs, resource_set):
    """Declares the `dart analyze` action; returns the stamp it writes on success."""
    dart_sdk_info = portable_sdk(ctx)
    stamp = ctx.actions.declare_file(name + ".analyzed")
    analyzer = _analyzer(ctx)
    args = analyzer.request
    args.add("--dart", dart_sdk_info.dart)
    _add_project(args, staged)
    args.add("--stamp", stamp)
    args.add("--fatal-infos")
    ctx.actions.run(
        executable = ctx.executable._analyze_tool,
        arguments = [analyzer.startup, args],
        inputs = depset(direct = staged.inputs, transitive = [sdk_inputs]),
        tools = analyzer.tools,
        outputs = [stamp],
        mnemonic = "DartAnalyze",
        exec_group = PORTABLE,
        resource_set = resource_set,
        progress_message = "Analyzing Dart sources of %{label}",
        env = SDK_ENV,
        execution_requirements = analyzer.execution_requirements,
    )
    return stamp

def _analyze_against_summaries(ctx, name, config, info, entry, own, analyzer, summaries):
    """Declares the analysis of `own` against the summaries of what it depends on; returns the stamp it writes on success.

    The staged project holds the target's own files, generated ones among
    them (no summary holds a target's own parts), and the options; every
    other library resolves from a summary, so an edit that leaves a
    dependency's summary unchanged does not re-run this action.
    """
    mine = [f for f in getattr(info, "srcs", []) if not f.short_path.startswith("../")]
    staged = stage_config_project(
        ctx,
        config,
        info.transitive_packages.to_list(),
        mine + entry + own,
        own,
        name + ".summaries",
        portable_sdk(ctx),
    )
    stamp = ctx.actions.declare_file(name + ".analyzed")
    args = ctx.actions.args()
    args.add("analyze")
    _add_project(args, staged)
    sdk_summary = summaries.sdk or analyzer.sdk_summary
    args.add("--sdk-summary", sdk_summary)
    args.add_all(summaries.deps, before_each = "--summary")
    args.add("--stamp", stamp)
    args.add("--fatal-infos")
    summary_analyzer_action(
        ctx,
        analyzer,
        args,
        depset(staged.inputs + [sdk_summary], transitive = [summaries.deps]),
        [stamp],
        "DartAnalyze",
        "Analyzing Dart sources of %{label} against summaries",
    )
    return stamp

def _format_language_versions(info, own_paths, default):
    """Groups a target's own files by the language version to format them at.

    The version is the one Dart itself would use: the version of the package
    whose root directory contains the file, `test/` and `bin/` included, not
    only `lib/`. A library states its package; an executable's entrypoint
    belongs to whichever in-repo package's root contains it — the package it
    sits in, not a dependency's — unless the executable states its own package,
    which then has a record like a library's. Formatting it at the SDK's newest version
    instead would demand a style the package's own `dart format` never produces
    once a package states a version below 3.7.

    Args:
      info: The target's `DartInfo` closure.
      own_paths: `short_path`s of the target's own files.
      default: The version of a package that states none
        (`default_language_version`).

    Returns:
      Dict of language version to the paths to format at it.
    """
    own = own_packages(info)
    if len(own) == 1:
        return {own[0].language_version or default: own_paths}

    # Several own packages are told apart by root like an entrypoint's.
    roots = own or [
        p
        for p in info.transitive_packages.to_list()
        if not p.package_root.startswith("../")
    ]
    groups = {}
    for path in own_paths:
        best = None
        for p in roots:
            if p.package_root == "" or path.startswith(p.package_root + "/"):
                if best == None or len(p.package_root) > len(best.package_root):
                    best = p
        version = (best.language_version if best else "") or default
        groups.setdefault(version, []).append(path)
    return groups

def _label(ctx):
    """The target's label as its user writes it: the aspect sees only this repository's."""
    return "//%s:%s" % (ctx.label.package, ctx.label.name)

def _format(ctx, name, staged, sdk_inputs, own_paths, language_version):
    """Declares a `dart format` action; returns the changes file it writes.

    Files are named individually rather than by handing the formatter the
    project: the staged tree also holds the rulesets the options include,
    none of which are this target's to format.

    `staged` is a project of its own, holding the target's files and the
    options alone. The formatter reads nothing else: its options come from the
    walk up from each file, and its language version from the command line.
    Staging the dependencies too, as the analyzer needs, would make an edit to
    any of them re-run this check on every target above it, with nothing it
    reads changed.
    """
    dart_sdk_info = portable_sdk(ctx)
    manifest = ctx.actions.declare_file(name + ".format_manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join(["src/%s\n" % p for p in own_paths]),
    )
    changes = ctx.actions.declare_file(name + ".format.json")
    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    _add_project(args, staged)
    args.add("--manifest", manifest)
    args.add("--changes", changes)
    args.add("--label", _label(ctx))

    # Always explicit, so no staged config can answer instead.
    args.add("--language-version", language_version)
    ctx.actions.run(
        executable = ctx.executable._format_tool,
        arguments = [args],
        inputs = depset(direct = staged.inputs + [manifest], transitive = [sdk_inputs]),
        outputs = [changes],
        mnemonic = "DartFormat",
        exec_group = PORTABLE,
        progress_message = "Formatting Dart sources of %{label}",
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
    )
    return changes

def _format_check(ctx, name, changes):
    """Declares the format check over `changes`; returns the stamp it writes when they propose nothing."""
    stamp = ctx.actions.declare_file(name + ".formatted")
    args = ctx.actions.args()
    args.add_all(changes, before_each = "--changes")
    args.add("--stamp", stamp)
    ctx.actions.run(
        executable = ctx.executable._format_check_tool,
        arguments = [args],
        inputs = changes,
        outputs = [stamp],
        mnemonic = "DartFormatCheck",
        exec_group = PORTABLE,
        progress_message = "Checking Dart formatting of %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return stamp

def _summaries(ctx, analyzer, info):
    """`info.summaries`, failing where analysis against them cannot run.

    Read from the provider the analysis stages, so a target reaches its
    libraries' summaries however its rule came by them (through another rule
    set's aspect, say), and an executable's analysis-only dependencies (a
    `sky_engine`) are among them.
    """
    if analyzer.error != None:
        fail(analyzer.error)
    summaries = getattr(info, "summaries", None)
    if summaries == None:
        fail(("%s: its `DartInfo` was not built by `dart_info()` (or `DartAnalyzableInfo` by " +
              "`dart_analyzable_info()`) and carries no analyzer summaries, which analysis " +
              "against summaries (`--@rules_dart//dart:analysis_summaries`, on by default) " +
              "reads. Build it with the constructors in `@rules_dart//dart:utils.bzl`, or " +
              "build with %s.") % (ctx.label, SUMMARIES_FLAG))
    if summaries.error != None:
        fail(summaries.error)
    return summaries

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
        entry = target[DartAnalyzableInfo].entry_srcs.to_list()

        # A package's own `lib/` files, which a target's `DefaultInfo` (a web
        # bundle, a test executable) need not list.
        package_srcs = list(info.srcs)
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

    name = ctx.label.name + ".dart_analyze"
    config = ctx.attr._config[DartAnalysisConfigInfo]

    # From source, the analyzer reads what compiles the target and what only
    # it reads: a `sky_engine` named in a dependency's `analysis_deps`.
    closure = analyzed_closure([info])
    srcs = closure.srcs.to_list()

    # What analyzing the whole program reserves (resources.bzl), by how many
    # Dart files it can see.
    resource_set = source_analysis_resources(len({
        f.path: None
        for f in srcs + entry + own.values()
        if f.extension == "dart"
    }))
    staged = stage_config_project(
        ctx,
        config,
        closure.packages.to_list(),
        srcs + closure.resources.to_list() + entry + own.values(),
        own.values(),
        name,
        portable_sdk(ctx),
    )

    dart_sdk_info = portable_sdk(ctx)
    sdk_inputs = dart_sdk_info.files.analyze

    tags = getattr(ctx.rule.attr, "tags", [])
    groups = {}
    analyzer = ctx.attr._summary_analyzer[DartSummaryAnalyzerInfo]
    if NO_ANALYZE_TAG not in tags:
        if analyzer.enabled:
            stamp = _analyze_against_summaries(ctx, name, config, info, entry, own.values(), analyzer, _summaries(ctx, analyzer, info))
        else:
            stamp = _analyze(ctx, name, staged, sdk_inputs, resource_set)
        groups["dart_analyze"] = depset([stamp])
    if NO_FORMAT_TAG not in tags:
        by_version = _format_language_versions(info, own_paths, default_language_version(dart_sdk_info))
        format_staged = stage_config_project(ctx, config, [], own.values(), own.values(), name + ".format", dart_sdk_info)
        changes = [
            _format(
                ctx,
                name if len(by_version) == 1 else "%s.%s" % (name, version),
                format_staged,
                dart_sdk_info.files.format,
                paths,
                version,
            )
            for version, paths in sorted(by_version.items())
        ]
        groups["dart_format_changes"] = depset(changes)
        groups["dart_format"] = depset([_format_check(ctx, name, changes)])

    # Write-back is limited to the target's own hand-written files, decided
    # from Bazel's record of what each file is rather than from its name:
    # `dart fix`'s built-in generated-file skip matches `*.g.dart` and nothing
    # else, so a `.freezed.dart` part would otherwise be rewritten.
    eligible = ctx.actions.declare_file(name + ".eligible")
    ctx.actions.write(
        output = eligible,
        content = "".join(["src/%s\t%s\n" % (p, p) for p in own_paths]),
    )
    fix_changes = ctx.actions.declare_file(name + ".fix.json")
    scratch = ctx.actions.declare_directory(name + ".scratch")
    fix_analyzer = _analyzer(ctx)
    fix_args = fix_analyzer.request
    fix_args.add("--dart", dart_sdk_info.dart)
    _add_project(fix_args, staged)
    fix_args.add_all([scratch], before_each = "--scratch", expand_directories = False)
    fix_args.add("--changes", fix_changes)
    fix_args.add("--label", _label(ctx))
    fix_args.add("--eligible", eligible)
    ctx.actions.run(
        executable = ctx.executable._fix_tool,
        arguments = [fix_analyzer.startup, fix_args],
        inputs = depset(direct = staged.inputs + [eligible], transitive = [sdk_inputs]),
        tools = fix_analyzer.tools,
        outputs = [fix_changes, scratch],
        mnemonic = "DartFix",
        exec_group = PORTABLE,
        resource_set = resource_set,
        progress_message = "Computing Dart fixes for %{label}",
        env = SDK_ENV,
        execution_requirements = fix_analyzer.execution_requirements,
    )

    return [OutputGroupInfo(dart_fix_changes = depset([fix_changes]), **groups)]

dart_analyze = aspect(
    implementation = _dart_analyze_aspect_impl,
    attrs = {
        "_summary_analyzer": attr.label(
            default = "//dart/private:summary_analyzer",
            providers = [DartSummaryAnalyzerInfo],
            cfg = config.exec(PORTABLE),
        ),
        "_config": attr.label(
            default = "//dart:analysis_config",
            providers = [DartAnalysisConfigInfo],
        ),
        "_analysis_host": attr.label(
            default = "//dart/private/tools:analysis_host.dart",
            allow_single_file = True,
        ),
        "_analysis_worker": attr.label(
            default = "//dart:analysis_worker",
        ),
        "_analyze_tool": attr.label(
            default = "//dart/private/tools:analyze_runner",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
        "_fix_tool": attr.label(
            default = "//dart/private/tools:fix_runner",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
        "_format_tool": attr.label(
            default = "//dart/private/tools:format_runner",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
        "_format_check_tool": attr.label(
            default = "//dart/private/tools:format_check",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Runs `dart analyze` and `dart format` on a Dart target's own files, and computes their fixes; see `@rules_dart//dart:analyze.bzl`.",
)
