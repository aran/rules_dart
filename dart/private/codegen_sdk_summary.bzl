"""The summary of the Dart SDK a codegen generator reads in place of its sources.

A generator built on the shim runner (`builder_shim_library`) resolves its
input with `package:analyzer`, which reads the SDK's libraries. From source
that is some 470 files staged into every codegen action and parsed again by
each; from a summary it is one file. `build_resolvers` does the same for
build_runner.

The analyzer's summaries carry no format version, and one written by another
version of the analyzer is misread rather than refused. So each generator
writes its own: an aspect on the codegen rules' `generator` runs it once per
generator and SDK, as `<generator> sdk-summary --sdk <dir> --out <file>`, and
the summary it writes is an input of every action that runs it. Two
generators built against different `analyzer`s never share one, and a new
`analyzer` is a new generator binary and so a new summary.

A package named `sky_engine` adds libraries to the SDK through its
`_embedder.yaml` (Flutter's `dart:ui`), which the analyzer reads only when it
reads the SDK from source; a codegen action that reaches one reads the SDK's
sources instead. A generator not built on the shim runner (the combining shim)
runs no analyzer and is given neither.
"""

load("//dart:providers.bzl", "DartAnalyzableInfo")
load("//dart/private:common.bzl", "PATH_MAPPING", "SDK_ENV", "sdk_path_from_dart")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_sdk")

visibility("//dart/...")

# The Dart package the shim runner is (`//dart/ext:pubspec-metadata`), whose
# `shimMain` writes the summary.
_SHIM_RUNNER_PACKAGE = "rules_dart_ext"

# The package whose `lib/_embedder.yaml` the analyzer reads
# (`package:sky_engine/_embedder.yaml`, `ContextBuilderImpl`).
_EMBEDDER_PACKAGE = "sky_engine"

CodegenSdkSummaryInfo = provider(
    doc = "The summary of the Dart SDK a codegen generator wrote with its own analyzer.",
    fields = {
        "summary": "File or None: the summary; None for a generator not built on the shim runner.",
    },
)

def _links_shim_runner(target):
    if DartAnalyzableInfo not in target:
        return False
    packages = target[DartAnalyzableInfo].dart_info.transitive_packages.to_list()
    return _SHIM_RUNNER_PACKAGE in [p.package_name for p in packages]

def _codegen_sdk_summary_impl(target, ctx):
    if not _links_shim_runner(target):
        return [CodegenSdkSummaryInfo(summary = None)]
    sdk = portable_sdk(ctx)
    summary = ctx.actions.declare_file(ctx.label.name + ".codegen_sdk.sum")
    args = ctx.actions.args()
    args.add("sdk-summary")
    args.add_all([sdk.dart], before_each = "--sdk", map_each = sdk_path_from_dart)
    args.add("--out", summary)
    ctx.actions.run(
        executable = target[DefaultInfo].files_to_run,
        arguments = [args],
        inputs = sdk.files.codegen,
        outputs = [summary],
        mnemonic = "DartCodegenSdkSummary",
        exec_group = PORTABLE,
        progress_message = "Summarizing the Dart %s SDK for %%{label}" % sdk.version,
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
    )
    return [CodegenSdkSummaryInfo(summary = summary)]

codegen_sdk_summary_aspect = aspect(
    implementation = _codegen_sdk_summary_impl,
    exec_groups = PORTABLE_EXEC_GROUPS,
    provides = [CodegenSdkSummaryInfo],
    doc = "Has a codegen generator built on the shim runner write the summary of the Dart SDK it reads.",
)

def codegen_sdk_args(args, ctx, packages):
    """Adds what a codegen action's generator reads of the Dart SDK to `args`.

    Args:
      args: The action's `Args`.
      ctx: The codegen rule's context; its `generator` carries
        `codegen_sdk_summary_aspect`.
      packages: The records of every package the generator may read.

    Returns:
      depset of the files of the SDK the action reads.
    """
    summary = ctx.attr.generator[CodegenSdkSummaryInfo].summary
    if summary == None:
        return depset()
    if _EMBEDDER_PACKAGE in [p.package_name for p in packages]:
        sdk = portable_sdk(ctx)
        args.add_all([sdk.dart], before_each = "--sdk-path", map_each = sdk_path_from_dart)
        return sdk.files.codegen
    args.add("--sdk-summary", summary)
    return depset([summary])
