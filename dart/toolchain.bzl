"""This module implements the Dart SDK toolchain rule."""

load("//dart/private:toolchains_repo.bzl", "SDK_CACHE_DIR")

# The SDK files each kind of use reads, as glob patterns relative to the SDK
# root. Measured on the pinned SDK by running each use against a copy holding
# only its set and taking one file away at a time; `//dart/tests/sdk_files`
# runs the uses against such copies, so a set that falls short on a new SDK
# fails there. Every action and runfiles tree takes only its own set: each
# input is linked into a sandbox and, remotely, listed, hashed and
# materialised, so 2 files beat the SDK's ~1,050. A set names both the POSIX
# and the Windows file; the one an SDK lacks matches nothing.
_DART = ["bin/dart", "bin/dart.exe"]
_DARTVM = ["bin/dartvm", "bin/dartvm.exe"]
_DARTAOTRUNTIME = ["bin/dartaotruntime", "bin/dartaotruntime.exe"]
_DARTDEV = ["bin/snapshots/dartdev_aot.dart.snapshot"]

# What the analyzer reads of the SDK it is pointed at: the `dart:` sources,
# `version` (the SDK's language version) and the experiments it allows.
_ANALYZER_SDK = [
    "lib/**/*.dart",
    "version",
    "lib/_internal/allowed_experiments.json",
]

SDK_FILE_SETS = {
    # The `dart` launcher and the VM it starts: runs a kernel or a Dart script
    # (the VM compiles source itself).
    "run": _DART + _DARTVM,
    # The runtime that runs an AOT snapshot.
    "aot_run": _DARTAOTRUNTIME,
    # `dart compile exe|aot-snapshot` from a kernel: dartdev, the front end
    # that tree-shakes, gen_snapshot, and the runtime `exe` prepends.
    "aot_compile": _DART + _DARTAOTRUNTIME + _DARTDEV + [
        "bin/snapshots/gen_kernel_aot.dart.snapshot",
        "bin/utils/gen_snapshot",
        "bin/utils/gen_snapshot.exe",
    ],
    # The front end run directly on the AOT runtime, as the kernel actions run
    # it: its snapshots, the VM platforms and the `dart:` library list. An
    # action takes only the files of this set it names.
    "kernel": _DARTAOTRUNTIME + [
        "bin/snapshots/kernel_worker_aot.dart.snapshot",
        "bin/snapshots/frontend_server_aot.dart.snapshot",
        "lib/_internal/vm_platform_product.dill",
        "lib/libraries.json",
    ],
    # `dart format`, which runs in dartdev.
    "format": _DART + _DARTDEV,
    # `dart analyze`, `dart fix`, and the analysis server run directly: the
    # server, the SDK it analyzes against, and the SDK's data-driven fixes.
    # The analysis worker hosts the server's JIT snapshot on the VM.
    "analyze": _DART + _DARTVM + _DARTAOTRUNTIME + _DARTDEV + _ANALYZER_SDK + [
        "bin/snapshots/analysis_server.dart.snapshot",
        "bin/snapshots/analysis_server_aot.dart.snapshot",
        "lib/_internal/fix_data.yaml",
    ],
    # A code generator built on `package:analyzer`, given the SDK's path.
    "codegen": _ANALYZER_SDK,
    # `dart compile js`, with the platforms its flags choose between.
    "dart2js": _DART + _DARTDEV + [
        "bin/snapshots/dart2js_aot.dart.snapshot",
        "lib/_internal/dart2js_platform.dill",
        "lib/_internal/dart2js_server_platform.dill",
        "lib/libraries.json",
    ],
    # `dart compile wasm`, with the platforms its flags choose between and the
    # optimizer it runs.
    "dart2wasm": _DART + _DARTAOTRUNTIME + _DARTDEV + [
        "bin/snapshots/dart2wasm_product.snapshot",
        "bin/utils/wasm-opt",
        "bin/utils/wasm-opt.exe",
        "lib/_internal/dart2wasm_platform.dill",
        "lib/_internal/dart2wasm_js_compatibility_platform.dill",
        "lib/_internal/dart2wasm_standalone_platform.dill",
    ],
}

DartSdkFilesInfo = provider(
    doc = """A Dart SDK's files, whole and by the use that reads them.

Made by `dart_sdk_files` over an SDK laid out as the Dart SDK archive is, so a
rule set holding its own copy of the SDK (Flutter's `bin/cache/dart-sdk`) gets
the same sets. Each field but `all` holds the files of the `SDK_FILE_SETS`
entry of that name.""",
    fields = {
        "all": "depset[File]: Every file of the SDK, for running any SDK command (`@rules_dart//dart`). An action or runfiles tree with one use takes that use's set instead. Pass as a `transitive` entry to action inputs or `ctx.runfiles(transitive_files = ...)`; flatten only to inspect paths.",
        "run": "depset[File]: `dart` and the VM: running a kernel or a Dart script.",
        "aot_run": "depset[File]: `dartaotruntime`: running an AOT snapshot.",
        "aot_compile": "depset[File]: `dart compile exe|aot-snapshot` from a kernel.",
        "kernel": "depset[File]: The front end's snapshots, the VM platforms and `libraries.json`, for actions that run the front end directly; such an action takes the files it names.",
        "format": "depset[File]: `dart format`.",
        "analyze": "depset[File]: `dart analyze`, `dart fix` and the analysis server.",
        "codegen": "depset[File]: What `package:analyzer` reads of the SDK it is pointed at.",
        "dart2js": "depset[File]: `dart compile js`.",
        "dart2wasm": "depset[File]: `dart compile wasm`.",
    },
)

def _dart_sdk_files_impl(ctx):
    sets = {}
    for role in SDK_FILE_SETS:
        files = getattr(ctx.attr, role)[DefaultInfo].files
        if not files:
            fail("%s: no SDK file matches the `%s` set: is this a Dart SDK laid out as its archive is?" % (ctx.label, role))
        sets[role] = files
    return [DartSdkFilesInfo(all = ctx.attr.all[DefaultInfo].files, **sets)]

_dart_sdk_files = rule(
    implementation = _dart_sdk_files_impl,
    attrs = dict(
        {role: attr.label(mandatory = True) for role in SDK_FILE_SETS},
        all = attr.label(mandatory = True),
    ),
    provides = [DartSdkFilesInfo],
    doc = "Collects the filegroups `dart_sdk_files` declares into a `DartSdkFilesInfo`.",
)

def dart_sdk_files(name, prefix = "", visibility = None):
    """Declares a `DartSdkFilesInfo` target over a Dart SDK in this package.

    Also declares one filegroup per set, `<name>_<set>`, and `<name>_all` for
    the whole SDK.

    Args:
      name: The target's name.
      prefix: Where the SDK root is in this package, with a trailing `/`
        (`dart-sdk/`); empty when the package is the SDK root.
      visibility: The targets' visibility.
    """
    native.filegroup(
        name = name + "_all",
        srcs = native.glob([prefix + "**"]),
        visibility = visibility,
    )
    for role, patterns in SDK_FILE_SETS.items():
        native.filegroup(
            name = "%s_%s" % (name, role),
            srcs = native.glob([prefix + p for p in patterns], allow_empty = True),
            visibility = visibility,
        )
    _dart_sdk_files(
        name = name,
        all = name + "_all",
        visibility = visibility,
        **{role: "%s_%s" % (name, role) for role in SDK_FILE_SETS}
    )

DartSdkInfo = provider(
    doc = "Information about the Dart SDK provided by the toolchain.",
    fields = {
        "dart": "File: The `dart` executable.",
        "version": "str: The SDK version string (e.g. `3.13.7`).",
        "files": "DartSdkFilesInfo: The SDK's files by the use that reads them.",
        "target_os": "str: Cross-compilation target OS (`macos`, `linux`, `windows`), or empty for native.",
        "target_arch": "str: Cross-compilation target architecture (`x64`, `arm64`, `riscv64`, `arm`), or empty for native.",
        "exec_os": "str: The OS the SDK's own binaries run on (`macos`, `linux`, `windows`).",
        "exec_arch": "str: The architecture the SDK's own binaries run on (`x64`, `arm64`).",
        "cross_tools": "struct | None: For a cross toolchain, what `dart compile` needs for the target that the SDK does not ship: `files`, a depset to add to the action's inputs, and `home`, the directory to give it as its home so it finds them. None for native.",
    },
)

def _cross_tools(ctx):
    if not ctx.files.sdk_cache:
        return None
    cache = "/%s/%s/" % (SDK_CACHE_DIR, ctx.attr.version)
    homes = {}
    for f in ctx.files.sdk_cache:
        home, sep, _ = f.path.rpartition(cache)
        if not sep:
            fail("%s: `sdk_cache` file %s is not under a `%s` directory" % (ctx.label, f.path, cache))
        homes[home] = None
    if len(homes) != 1:
        fail("%s: `sdk_cache` files are under more than one home: %s" % (ctx.label, sorted(homes)))
    return struct(
        files = depset(ctx.files.sdk_cache),
        home = homes.keys()[0],
    )

def _dart_toolchain_impl(ctx):
    files = ctx.attr.sdk[DartSdkFilesInfo]
    if ctx.file.dart not in files.run.to_list():
        fail("%s: `dart` (%s) is not in its SDK's `run` set" % (ctx.label, ctx.file.dart.path))

    dart_sdk_info = DartSdkInfo(
        dart = ctx.file.dart,
        version = ctx.attr.version,
        files = files,
        target_os = ctx.attr.target_os,
        target_arch = ctx.attr.target_arch,
        exec_os = ctx.attr.exec_os,
        exec_arch = ctx.attr.exec_arch,
        cross_tools = _cross_tools(ctx),
    )

    template_variables = platform_common.TemplateVariableInfo({
        "DART_BIN": ctx.file.dart.path,
    })
    default = DefaultInfo(
        files = files.all,
        runfiles = ctx.runfiles(transitive_files = files.all),
    )

    toolchain_info = platform_common.ToolchainInfo(
        dart_sdk_info = dart_sdk_info,
        template_variables = template_variables,
        default = default,
    )
    return [
        default,
        toolchain_info,
        template_variables,
    ]

dart_toolchain = rule(
    implementation = _dart_toolchain_impl,
    attrs = {
        "dart": attr.label(
            doc = "The `dart` executable from the SDK's `bin/` directory.",
            mandatory = True,
            allow_single_file = True,
        ),
        "sdk": attr.label(
            doc = "The SDK's files: a `dart_sdk_files` target over the SDK `dart` belongs to.",
            mandatory = True,
            providers = [DartSdkFilesInfo],
        ),
        "sdk_cache": attr.label(
            doc = "For a cross toolchain, the files `dart compile` would otherwise download for the target, at `<home>/" + SDK_CACHE_DIR + "/<version>/<basename>`. Typically a `dart_cross_tools` repository's `:sdk_cache`.",
            allow_files = True,
        ),
        "version": attr.string(
            doc = "The SDK version string (e.g. `3.13.7`).",
            mandatory = True,
        ),
        "target_os": attr.string(
            doc = "Cross-compilation target OS (`macos`, `linux`, `windows`). Leave empty for native compilation.",
        ),
        "target_arch": attr.string(
            doc = "Cross-compilation target architecture (`x64`, `arm64`). Leave empty for native compilation.",
        ),
        "exec_os": attr.string(
            doc = "The OS the SDK's own binaries run on (`macos`, `linux`, `windows`).",
            mandatory = True,
        ),
        "exec_arch": attr.string(
            doc = "The architecture the SDK's own binaries run on (`x64`, `arm64`).",
            mandatory = True,
        ),
    },
    doc = "Defines a Dart SDK toolchain. Typically generated by the `dart_repositories` repository rule.",
)

def _dart_outline_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        outline_tool = ctx.attr.tool[DefaultInfo].files_to_run if ctx.attr.tool else None,
        version = ctx.attr.version,
    )]

dart_outline_toolchain = rule(
    implementation = _dart_outline_toolchain_impl,
    attrs = {
        "tool": attr.label(
            doc = "The outline stripper, built on the `pkg/kernel` of the SDK `version` names, such as a `dart_kernel_source` repository's `:outline_tool`. Leave it unset when `@rules_dart//dart:is_outline_kernel` is not, so that it is not built: `select({\"@rules_dart//dart:is_outline_kernel\": ..., \"//conditions:default\": None})`.",
            executable = True,
            # Built for the platform the kernel SDK resolving it is configured
            # for: the host the module actions run on.
            cfg = "target",
        ),
        "version": attr.string(
            doc = "The version of the Dart SDK whose `pkg/kernel` `tool` is built on: the `version` of the `dart_toolchain` whose kernels it reads.",
            mandatory = True,
        ),
    },
    doc = """The outline stripper for the kernels of one Dart SDK: a toolchain of type `@rules_dart//dart:outline_toolchain_type`.

With `--@rules_dart//dart:outline_kernel` on, the Dart VM's kernel modules are
stripped to outlines by the stripper of the toolchain that resolves, which must
be of the same SDK `version` as the Dart toolchain that compiled them. The
`dart` extension registers one beside each Dart toolchain. A Dart SDK of your
own (a fork, a local build) registers its own, built from its `pkg/kernel`.""",
)

_SUMMARIES = "//dart:analysis_summaries"

def _without_summaries_impl(_settings, _attr):
    return {_SUMMARIES: False}

# The summary analyzer is built of Dart libraries, and every library declares
# its summary with the summary analyzer: built with summaries on, it would
# depend on itself. Nothing analyzes the tool's own libraries.
_without_summaries = transition(
    implementation = _without_summaries_impl,
    inputs = [],
    outputs = [_SUMMARIES],
)

def _dart_analyzer_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        # A list: the attribute has a transition.
        summary_analyzer = ctx.attr.tool[0][DefaultInfo].files_to_run if ctx.attr.tool else None,
        version = ctx.attr.version,
    )]

dart_analyzer_toolchain = rule(
    implementation = _dart_analyzer_toolchain_impl,
    attrs = {
        "tool": attr.label(
            doc = "The summary analyzer, built on the `pkg/analyzer` and `pkg/linter` of the SDK `version` names, such as a `dart_analyzer_source` repository's `:summary_analyzer`. Leave it unset when `@rules_dart//dart:is_analysis_summaries` is not, so that it is not built: `select({\"@rules_dart//dart:is_analysis_summaries\": ..., \"//conditions:default\": None})`.",
            executable = True,
            # Built for the platform the rule resolving it is configured for
            # (the host the analysis actions run on), with summaries off.
            cfg = _without_summaries,
        ),
        "version": attr.string(
            doc = "The version of the Dart SDK whose `pkg/analyzer` and `pkg/linter` `tool` is built on: the `version` of the `dart_toolchain` whose analysis it stands in for.",
            mandatory = True,
        ),
    },
    doc = """The summary analyzer of one Dart SDK: a toolchain of type `@rules_dart//dart:analyzer_toolchain_type`.

With `--@rules_dart//dart:analysis_summaries` on, the `dart_analyze` aspect
analyzes against dependencies' summaries with the analyzer of the toolchain
that resolves, which must be of the same SDK `version` as the Dart toolchain
of the analysis. The `dart` extension registers one beside each Dart toolchain.
A Dart SDK of your own (a fork, a local build) registers its own, built from its
`pkg/analyzer` and `pkg/linter` (`dart_analyzer_source(path = ...)`).""",
)
