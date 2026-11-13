"""Analyzer summaries: what `--@rules_dart//dart:analysis_summaries` analyzes against.

A summary is the analyzer's record of a library's declarations without its
bodies, offsets or comments (a "package bundle"). The rule that builds a
library's `DartInfo` declares the action writing its summary, from its own
sources read against its dependencies' summaries, and `DartInfo.summaries`
carries it with every summary the library depends on, as `GoArchive` carries
export data and `JavaInfo` header jars. Nothing builds a summary until an
analysis reads it: the `dart_analyze` aspect analyzes a target's own files
against the summaries its provider carries instead of their source. An edit
that changes no declaration (a function body, a comment) leaves its library's
summary byte for byte the same, so Bazel re-runs no analysis of the targets
above it.

No tool in the Dart SDK reads summaries: the SDK dropped analysis against
them with the analyzer's build mode. The summary analyzer
(`//dart/private/tools:summary_analyzer.dart`) is built on the SDK's own
`pkg/analyzer` and `pkg/linter`, unmodified, by the analyzer toolchain
(`//dart:analyzer_toolchain_type`) of the SDK; it refuses wherever summaries
are known to change the analyzer's answer.

Whatever stops a summary being written (no analyzer toolchain for the SDK, a
dependency whose rule declares no summaries, two SDK embedders) is recorded in
`DartInfo.summaries.error` and reported by the analysis that needs it, so a
build that analyzes nothing never fails over summaries.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart/private:common.bzl", "PATH_MAPPING", "SDK_ENV")
load("//dart/private:dart_info.bzl", "dart_info_with_summaries", "dep_summaries", "summaries_info")
load("//dart/private:exec_groups.bzl", "PORTABLE", "portable_sdk")
load("//dart/private:project_staging.bzl", "resolve_package_exec_roots_from_outside", "staged_package_config_content")
load("//dart/private:resources.bzl", "analysis_resources")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "package_record_for_index", "package_record_index")

visibility("//dart/...")

SUMMARIES_FLAG = "--@rules_dart//dart:analysis_summaries=false"

DartSummaryAnalyzerInfo = provider(
    doc = "The summary analyzer and the summary of the SDK it analyzes against, or `enabled = False` with `--@rules_dart//dart:analysis_summaries` off.",
    fields = {
        "enabled": "bool: Whether analysis runs against summaries.",
        "error": "str or None: Why no summary analyzer is available, reported by an analysis that needs one.",
        "tool": "FilesToRunProvider: The summary analyzer.",
        "sdk_summary": "File: The SDK's summary.",
        "version": "str: The version of the SDK.",
    },
)

def _analyzer_toolchain_error(ctx, sdk):
    toolchain = ctx.toolchains["//dart:analyzer_toolchain_type"]
    why = None
    if toolchain == None:
        why = "no analyzer toolchain (`@rules_dart//dart:analyzer_toolchain_type`) is registered for it"
    elif toolchain.summary_analyzer == None:
        why = "its analyzer toolchain has no `tool`"
    elif toolchain.version != sdk.version:
        why = "the analyzer toolchain that resolved is of the Dart %s SDK, and analysis must use the analyzer of its own SDK" % toolchain.version
    if why == None:
        return None
    return (("Analysis against analyzer summaries (`--@rules_dart//dart:analysis_summaries`, on by " +
             "default) needs an analyzer built from the unmodified source of the Dart SDK it analyzes " +
             "for, %s, but %s. A released Dart SDK has its analyzer from its release tag " +
             "(`dart_analyzer_source(dart_version = ...)`); a Dart SDK with no release tag (a Flutter " +
             "beta or main channel, a local build) has none unless you register a " +
             "`dart_analyzer_toolchain` built from its checkout (`dart_analyzer_source(path = ...)`). " +
             "To analyze against dependencies' source instead, build with %s (in `.bazelrc`: " +
             "`common %s`).") % (sdk.version, why, SUMMARIES_FLAG, SUMMARIES_FLAG))

def _summary_analyzer_impl(ctx):
    if not ctx.attr.enabled:
        return [DartSummaryAnalyzerInfo(enabled = False, error = None, tool = None, sdk_summary = None, version = None), DefaultInfo()]
    sdk = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info

    # Configured for every library's summary, built only for an analysis: a
    # build that analyzes nothing must not fail for want of an analyzer.
    error = _analyzer_toolchain_error(ctx, sdk)
    if error != None:
        return [DartSummaryAnalyzerInfo(enabled = True, error = error, tool = None, sdk_summary = None, version = sdk.version), DefaultInfo()]
    tool = ctx.toolchains["//dart:analyzer_toolchain_type"].summary_analyzer
    sdk_summary = ctx.actions.declare_file(ctx.label.name + "/sdk.sum")
    args = ctx.actions.args()
    args.add("sdk-summary")
    args.add("--sdk", sdk.dart.dirname.rpartition("/")[0])
    args.add("--out", sdk_summary)
    ctx.actions.run(
        executable = tool,
        arguments = [args],
        inputs = sdk.files.codegen,
        outputs = [sdk_summary],
        mnemonic = "DartSdkSummary",
        toolchain = "//dart:analyzer_toolchain_type",
        progress_message = "Summarizing the Dart %s SDK" % sdk.version,
        env = SDK_ENV,
    )
    return [
        DartSummaryAnalyzerInfo(enabled = True, error = None, tool = tool, sdk_summary = sdk_summary, version = sdk.version),
        DefaultInfo(files = depset([sdk_summary])),
    ]

summary_analyzer = rule(
    implementation = _summary_analyzer_impl,
    attrs = {
        "enabled": attr.bool(doc = "`--@rules_dart//dart:analysis_summaries`."),
    },
    toolchains = [
        "//dart:toolchain_type",
        # Resolved with the flag off too, when its `tool` is unset.
        config_common.toolchain_type("//dart:analyzer_toolchain_type", mandatory = False),
    ],
    doc = "The summary analyzer of the resolved Dart toolchain's SDK, and that SDK's summary.",
)

# What a rule building `DartInfo` with `dart_info()` merges into its `attrs`,
# beside `exec_groups = PORTABLE_EXEC_GROUPS` and `COPY_TO_DIRECTORY_TOOLCHAINS`
# among its `toolchains`, so that it declares its library's summary.
SUMMARY_ATTRS = {
    "_summary_analyzer": attr.label(
        default = "//dart/private:summary_analyzer",
        providers = [DartSummaryAnalyzerInfo],
        # Built for the host the summary actions run on.
        cfg = config.exec(PORTABLE),
    ),
    "_analysis_worker": attr.label(default = "//dart:analysis_worker"),
}

def _analyzer_execution(ctx, args):
    """`execution_requirements` for a summary analyzer action; puts `args` in a param file.

    A worker takes its arguments from one always. Without one, they move to
    a param file when they outgrow the command line, as they do with the
    summary of every library a deep graph reaches (Windows allows 32,767
    characters).
    """
    args.set_param_file_format("multiline")
    if not ctx.attr._analysis_worker[BuildSettingInfo].value:
        args.use_param_file("@%s")
        return PATH_MAPPING
    args.use_param_file("@%s", use_always = True)
    return PATH_MAPPING | {
        "requires-worker-protocol": "proto",
        "supports-workers": "1",
    }

def summary_analyzer_action(ctx, analyzer, args, inputs, outputs, mnemonic, progress_message):
    """Runs the summary analyzer, in a persistent worker unless `analysis_worker` is off.

    Args:
      ctx: A rule or aspect context with `SUMMARY_ATTRS` and `PORTABLE_EXEC_GROUPS`.
      analyzer: The `DartSummaryAnalyzerInfo`.
      args: The command's `Args`, its first argument the command; the SDK
        summary must be among `inputs`.
      inputs: depset of the inputs.
      outputs: The outputs.
      mnemonic: The action's mnemonic.
      progress_message: Its progress message.
    """
    ctx.actions.run(
        executable = analyzer.tool,
        arguments = [args],
        inputs = inputs,
        outputs = outputs,
        mnemonic = mnemonic,
        exec_group = PORTABLE,
        resource_set = analysis_resources,
        progress_message = progress_message,
        env = SDK_ENV,
        execution_requirements = _analyzer_execution(ctx, args),
    )

def _project_of_config(config):
    # `<project>/.dart_tool/package_config.json`.
    return config.dirname.rpartition("/")[0]

_EMPTY_OPTIONS = "# rules_dart: a summary is the same under any options\n"

def _summarize(ctx, analyzer, sdk_summary, packages, srcs, deps):
    """Declares the action writing the summary of `srcs`; returns the summary."""
    name = ctx.label.name + ".dart_summary"
    index = package_record_index(packages)
    by_record = {}
    for f in srcs:
        record = package_record_for_index(f.short_path, index)
        if record != None:
            by_record.setdefault((record.package_name, record.package_root), []).append(f)
    config = ctx.actions.declare_file(name + "/.dart_tool/package_config.json")
    resolved = resolve_package_exec_roots_from_outside(ctx, name, by_record, config)
    ctx.actions.write(
        config,
        staged_package_config_content(
            packages,
            {key: r.root_uri for key, r in resolved.items()},
        ),
    )

    # Its own options file, so the analyzer never walks up past the project
    # to whatever `analysis_options.yaml` the execution root holds.
    options = ctx.actions.declare_file(name + "/analysis_options.yaml")
    ctx.actions.write(options, _EMPTY_OPTIONS)
    files = [f for r in resolved.values() for f in r.files]

    summary = ctx.actions.declare_file(name + ".sum")
    args = ctx.actions.args()
    args.add("summarize")
    args.add_all([config], before_each = "--project", map_each = _project_of_config)
    args.add("--options", options)
    args.add("--sdk-summary", sdk_summary)
    args.add_all(deps, before_each = "--summary")
    args.add_all(files, before_each = "--file", expand_directories = False)
    args.add("--out", summary)
    summary_analyzer_action(
        ctx,
        analyzer,
        args,
        depset(files + [config, options, sdk_summary], transitive = [deps]),
        [summary],
        "DartSummarize",
        "Summarizing Dart libraries of %{label}",
    )
    return summary

_EMBEDDER = "_embedder.yaml"

def _own_embedder(packages, resources):
    """The `lib/_embedder.yaml` among `resources` of a package named `sky_engine`, or None.

    The analyzer reads the embedder of the package of that name alone
    (`package:sky_engine/_embedder.yaml`, `ContextBuilderImpl`).
    """
    paths = [(p.package_root + "/lib/" if p.package_root else "lib/") + _EMBEDDER for p in packages if p.package_name == "sky_engine"]
    for f in resources:
        if f.short_path in paths:
            return f
    return None

def _embedder_sdk_summary(ctx, analyzer, srcs, embedder):
    """Declares the summary of the SDK with the libraries `embedder` adds."""
    sdk = portable_sdk(ctx)
    out = ctx.actions.declare_file(ctx.label.name + ".dart_summary/sdk.sum")
    args = ctx.actions.args()
    args.add("sdk-summary")
    args.add("--sdk", sdk.dart.dirname.rpartition("/")[0])
    args.add("--embedder", embedder)
    args.add("--out", out)
    summary_analyzer_action(
        ctx,
        analyzer,
        args,
        depset(srcs + [embedder], transitive = [sdk.files.codegen]),
        [out],
        "DartSdkSummary",
        "Summarizing the Dart SDK with the libraries of %{label}",
    )
    return out

def _undeclared_error(ctx, missing):
    return (("%s: its rule builds `DartInfo` with `dart_info()` but declares no %s, so it cannot " +
             "declare its library's summary, which analysis against summaries " +
             "(`--@rules_dart//dart:analysis_summaries`, on by default) reads. A rule building " +
             "`DartInfo` merges `SUMMARY_ATTRS` into its `attrs`, takes `exec_groups = " +
             "PORTABLE_EXEC_GROUPS` and lists `COPY_TO_DIRECTORY_TOOLCHAINS` among its " +
             "`toolchains` (all from `@rules_dart//dart:utils.bzl`). To analyze against " +
             "dependencies' source instead, build with %s.") % (ctx.label, missing, SUMMARIES_FLAG))

def _missing_declaration(ctx):
    if not hasattr(ctx.attr, "_summary_analyzer"):
        return "`SUMMARY_ATTRS`"
    if PORTABLE not in ctx.exec_groups:
        return "`PORTABLE_EXEC_GROUPS`"
    for toolchain in COPY_TO_DIRECTORY_TOOLCHAINS:
        if toolchain not in ctx.toolchains:
            return "`COPY_TO_DIRECTORY_TOOLCHAINS`"
    return None

def _own_summaries(ctx, packages, srcs, resources, deps):
    """`DartInfo.summaries` of a library: its own summary, or why it has none, and its dependencies'."""
    merged = dep_summaries(ctx.label, deps)
    srcs = [f for f in srcs if f.is_directory or f.extension == "dart"]
    embedder = _own_embedder(packages, resources)
    if not srcs and embedder == None:
        return summaries_info(merged)
    missing = _missing_declaration(ctx)
    if missing != None:
        return summaries_info(merged, error = _undeclared_error(ctx, missing))
    analyzer = ctx.attr._summary_analyzer[DartSummaryAnalyzerInfo]
    if not analyzer.enabled:
        return summaries_info(merged)
    if analyzer.error != None:
        return summaries_info(merged, error = analyzer.error)
    if merged.error != None:
        return summaries_info(merged)
    if analyzer.version != portable_sdk(ctx).version:
        return summaries_info(merged, error = (
            ("%s: analysis runs with the Dart %s SDK, but the summary analyzer is of the Dart %s SDK. " +
             "Register the analyzer toolchain of the Dart %s SDK, or build with %s.") %
            (ctx.label, portable_sdk(ctx).version, analyzer.version, portable_sdk(ctx).version, SUMMARIES_FLAG)
        ))

    # Flutter's `sky_engine` adds libraries to the SDK (`dart:ui`), which the
    # analyzer finds through its `_embedder.yaml`: what reaches it reads them
    # as part of the SDK, as `dart analyze` does. Its own files are those
    # libraries, which no package summary holds.
    if embedder != None:
        if merged.sdk != None:
            return summaries_info(merged, error = (
                "%s: adds libraries to the Dart SDK with an `%s`, and so does %s, which it depends on; analysis against summaries reads one SDK. Build with %s to analyze from source." %
                (ctx.label, _EMBEDDER, merged.sdk_owner, SUMMARIES_FLAG)
            ))
        return summaries_info(
            merged,
            sdk_summary = _embedder_sdk_summary(ctx, analyzer, srcs + resources, embedder),
            sdk_owner = ctx.label,
        )
    return summaries_info(
        merged,
        summary = _summarize(ctx, analyzer, merged.sdk or analyzer.sdk_summary, packages, srcs, merged.transitive),
    )

def dart_info(
        ctx,
        packages,
        deps = [],
        srcs = [],
        resources = [],
        indirect_deps = [],
        analysis_deps = [],
        data = []):
    """Builds a `DartInfo` for a library, merging its dependencies' closures.

    The caller supplies only what this target contributes itself; everything
    transitive is merged here (see `dart_info.bzl`). Adding a field to
    `DartInfo` is therefore a change in rules_dart and nothing else.

    A library contributes one package, its record built from its declaration
    (`library_package()`) or by `DartPackageInfo(...)`, or several: pub allows
    packages to depend on each other (`dio` and `dio_web_adapter`), Bazel does
    not allow a dependency cycle, so the packages of such a cycle are one
    target, compiled together, each keeping its own name and `package_root`. A target contributing none is what
    `dart_info_no_package()` is for.

    It also declares the action writing the library's analyzer summary, which
    runs only when an analysis reads it, so the rule merges `SUMMARY_ATTRS`
    into its `attrs`, takes `exec_groups = PORTABLE_EXEC_GROUPS` and lists
    `COPY_TO_DIRECTORY_TOOLCHAINS` among its `toolchains`. A rule that does not
    builds a `DartInfo` whose analysis against summaries fails, naming what it
    lacks.

    Attribute hygiene stays with the calling rule — whether `srcs` and
    `srcs_dir` are mutually exclusive, whether a file sits under the package's
    `lib/` — because those are statements about that rule's attributes, and a
    rule generating its package as one tree artifact has no such files to check.

    Args:
      ctx: The constructing rule's context.
      packages: The `DartPackageInfo` records this target contributes, each
        from `library_package()` or `DartPackageInfo(...)`. At least one.
      deps: Targets providing `DartInfo` whose closures are merged in.
      srcs: This target's own Dart sources (or its source directory), of all
        its packages.
      resources: This target's own non-Dart files under its packages' `lib/`.
      indirect_deps: Labels of targets that one of `deps` depends on and this
        target's sources import, for sources whose imports a generator
        chooses: `dart_proto_library`'s code imports the `fixnum` its protobuf
        runtime is built on. Found by package in a dependency's
        `DartInfo.deps`, so nobody names them by hand; the layering check
        accepts their packages as direct.
      analysis_deps: Targets providing `DartInfo` that the analyzer reads and
        the compiler does not, whose summaries this library's summary is read
        against and hands on: Flutter's `sky_engine`, whose `_embedder.yaml`
        gives the analyzer `dart:ui`, which the compiler takes from its SDK.
        Their closures join `DartInfo.analysis_only`, which whatever analyzes
        or generates code from source above this library stages, and nothing
        compiles.
      data: Targets whose files and runfiles the library needs at run time,
        as `py_library`'s `data`: never compile inputs, they join the
        runfiles of every executable that reaches the library
        (`DartInfo.runfiles`).

    Returns:
      A `DartInfo`.
    """
    return dart_info_with_summaries(
        label = ctx.label,
        packages = packages,
        deps = deps,
        srcs = srcs,
        resources = resources,
        indirect_deps = indirect_deps,
        analysis_deps = analysis_deps,
        summaries = _own_summaries(ctx, packages, srcs, resources, deps + analysis_deps),
        runfiles = _data_runfiles(ctx, data) if data else None,
    )

def _data_runfiles(ctx, data):
    """The runfiles of `data` targets: their files and their own runfiles.

    Args:
      ctx: The rule context.
      data: Targets.

    Returns:
      A runfiles object.
    """
    return ctx.runfiles(
        transitive_files = depset(transitive = [t[DefaultInfo].files for t in data]),
    ).merge_all([t[DefaultInfo].default_runfiles for t in data])
