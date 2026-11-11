"""Package-level aggregate Dart code generation.

Unlike per-file `dart_codegen`, `dart_aggregate_codegen` takes ALL sources
in a Dart package and produces one or more aggregate outputs. Used by
any `PackageBuilder` that needs a whole-package view of metadata.

The generator (`generator_bin` binary or `generator_script`) receives:

  - `--input <path>`: the primary input (first entry in `srcs`).
  - `--input-asset <asset>`: the primary's Dart asset path.
  - `--input-asset-extra <exec>|<asset>` (repeatable): one per additional
    source in `srcs`. Exposed to the Builder as primary asset inputs.
  - `--output <path>` (repeatable): one per `outputs` entry. Multi-output
    aggregates (e.g. a builder emitting both `.config.dart` and
    `.module.dart`) declare all paths here.
  - `--dep <exec>|<asset>` (repeatable): one per auto-staged sibling.
  - `--part <path>` (repeatable): each `parts` entry.
  - `--package <name>`: the Dart package name.
  - `--config <json>`: builder options as a JSON object string.
  - `--package-config <path>`: synthesised from `deps`.
  - `--root-language-version <major.minor>`.
  - `--sdk-path <path>`.

Usage:

    load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen")

    dart_aggregate_codegen(
        name = "di_config",
        srcs = [":metadata_shards"] + SAME_PACKAGE_SOURCES,
        generator_bin = "//tools:my_aggregate_shim",
        outputs = ["lib/main.config.dart", "lib/main.module.dart"],
        deps = ["@pub_deps//:my_annotations"],
        package = ":pubspec-metadata",
    )

`deps` is a list of `dart_library`-shaped targets (anything exporting
`DartInfo`). Their transitive sources populate a synthesised
`package_config.json` for the shim's analyzer; any same-package sibling
not already in `srcs` is auto-staged as `--dep`.

Worker mode (`supports-workers=1`, protobuf, singleplex) is enabled for
`generator_bin` actions; worker requests go through `dart/ext/lib/worker_entry.dart`.
"""

load("//dart:providers.bzl", "DartInfo")
load(
    "//dart/private:common.bzl",
    "PATH_MAPPING",
    "add_shim_contract_args",
    "asset_path_for",
    "codegen_identity",
    "dart_package_root_for_package",
    "format_literal",
    "package_identity_attrs",
    "resolve_package_identity",
    "same_package_library_dep_files",
    "synth_package_config",
)
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_sdk")
load("//dart/private:runtime.bzl", "non_dart_transition")

def _dart_aggregate_codegen_impl(ctx):
    identity = resolve_package_identity(ctx)
    dart_sdk_info = portable_sdk(ctx)

    if ctx.file.generator_script and ctx.executable.generator_bin:
        fail("%s: only one of `generator_bin` or `generator_script` may be set." %
             ctx.label)
    if not ctx.file.generator_script and not ctx.executable.generator_bin:
        fail("%s: either `generator_bin` or `generator_script` must be set." %
             ctx.label)
    if not ctx.attr.outputs:
        fail("%s: `outputs` must contain at least one path." % ctx.label)
    if not ctx.files.srcs:
        fail("%s: `srcs` cannot be empty." % ctx.label)

    outputs = [ctx.actions.declare_file(path) for path in ctx.attr.outputs]
    synth_pc, package_files = synth_package_config(ctx, ctx.attr.deps)

    package_root_from_deps = dart_package_root_for_package(
        ctx.attr.deps,
        identity.package_name,
    )
    package_root = identity.package_root
    if identity.metadata == None and package_root_from_deps != None:
        package_root = package_root_from_deps

    src_paths = [s.path for s in ctx.files.srcs]
    auto_staged, _ = same_package_library_dep_files(
        ctx.attr.deps,
        identity.package_name,
        exclude_paths = src_paths,
    )

    args = ctx.actions.args()

    # Configure param-file up-front when a worker binary is used so the
    # flagfile convention (`@<path>`, multiline) is set before any args
    # are added. Matches `dart_codegen`'s ordering.
    if ctx.executable.generator_bin:
        args.use_param_file("@%s", use_always = True)
        args.set_param_file_format("multiline")
    primary = ctx.files.srcs[0]
    args.add("--input", primary)
    args.add("--input-asset", asset_path_for(primary, package_root))
    for output in outputs:
        args.add("--output", output)
    for src in ctx.files.srcs[1:]:
        args.add("--input-asset-extra", src, format = "%s|" + format_literal(asset_path_for(src, package_root)))
    extra_inputs = add_shim_contract_args(
        args,
        ctx,
        synth_pc,
        dart_sdk_info.dart,
        auto_stage_srcs = auto_staged,
        asset_deps = ctx.files.asset_deps,
        package_root = package_root,
    )
    args.add_all(ctx.attr.generator_args)

    direct_inputs = list(ctx.files.srcs) + extra_inputs
    transitive = [package_files] if package_files != None else []

    # What the generator's analyzer reads of the SDK at `--sdk-path`.
    transitive.append(dart_sdk_info.files.codegen)

    if ctx.executable.generator_bin:
        ctx.actions.run(
            executable = ctx.executable.generator_bin,
            arguments = [args],
            inputs = depset(direct = direct_inputs, transitive = transitive),
            outputs = outputs,
            mnemonic = "DartAggregateCodegen",
            exec_group = PORTABLE,
            progress_message = "DartAggregateCodegen %s" % ctx.label,
            execution_requirements = PATH_MAPPING | {
                "supports-workers": "1",
                "requires-worker-protocol": "proto",
                "worker-key-mnemonic": "DartAggregateCodegen",
            },
        )
    else:
        ctx.actions.run(
            executable = dart_sdk_info.dart,
            arguments = [ctx.actions.args().add(ctx.file.generator_script), args],
            inputs = depset(
                direct = [ctx.file.generator_script] + direct_inputs,
                # A script runs in the VM besides.
                transitive = transitive + [dart_sdk_info.files.run],
            ),
            outputs = outputs,
            mnemonic = "DartAggregateCodegen",
            exec_group = PORTABLE,
            progress_message = "DartAggregateCodegen %s" % ctx.label,
            execution_requirements = PATH_MAPPING,
        )

    return [
        DefaultInfo(files = depset(outputs)),
        # The *effective* values, the SDK's version included: a library stating
        # an older one over a generator that states none is exactly the
        # disagreement `codegen_identity_error` exists to name.
        codegen_identity(identity),
    ]

dart_aggregate_codegen = rule(
    implementation = _dart_aggregate_codegen_impl,
    # Its outputs are the same under every web compiler, whether or not
    # creation locations are tracked and whatever environment the executable
    # above it compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "srcs": attr.label_list(
            doc = "All source files the builder analyses. The first " +
                  "entry is the primary input passed as `--input` (its " +
                  "extension must match one in the builder's " +
                  "`buildExtensions` map); the rest are passed as " +
                  "`--input-asset-extra` and staged so the Builder's " +
                  "`findAssets` / `readAsString` see them. Typically a " +
                  "mix of `.dart` source files and generated data shards " +
                  "(e.g. `.metadata.json` shards from a per-file stage).",
            allow_files = True,
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "`dart_library`-shaped targets (anything exporting " +
                  "`DartInfo`) whose transitive sources populate a " +
                  "synthesised `package_config.json`. Same-package " +
                  "siblings not already in `srcs` are auto-staged as " +
                  "`--dep`.",
            providers = [DartInfo],
        ),
        "generator_bin": attr.label(
            doc = "Pre-compiled generator executable matching the " +
                  "rules_dart shim CLI contract. Mutually exclusive " +
                  "with `generator_script`.",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
        "generator_script": attr.label(
            doc = "A `.dart` script the SDK's `dart` runs as the " +
                  "generator. Mutually exclusive with `generator_bin`.",
            allow_single_file = [".dart"],
        ),
        "outputs": attr.string_list(
            doc = "Output file paths (package-relative). One entry per " +
                  "builder-produced extension — e.g. `['lib/app.config.dart', " +
                  "'lib/app.module.dart']` for a builder emitting both.",
            mandatory = True,
        ),
        "parts": attr.label_list(
            doc = "Additional input files passed as `--part <path>` " +
                  "(for combining-style aggregates).",
            allow_files = True,
        ),
        "config": attr.string(
            doc = "Builder options as a JSON object string. Passed as " +
                  "`--config <json>`.",
        ),
        "package_config": attr.label(
            doc = "Optional pre-existing `package_config.json`; overrides " +
                  "the one synthesised from `deps`.",
            allow_single_file = True,
        ),
        "generator_args": attr.string_list(
            doc = "Escape-hatch additional arguments. Prefer the typed " +
                  "attrs above.",
        ),
        "asset_deps": attr.label_list(
            doc = "Non-Dart files the Builder's `Resolver` / `findAssets` " +
                  "must see (e.g. generated data shards, JSON/YAML " +
                  "sidecars). Each file is staged and passed as " +
                  "`--dep <exec>|<asset>` using `asset_path_for`.",
            allow_files = True,
        ),
    } | package_identity_attrs(),
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Runs a package-level aggregate Dart code generator, producing " +
          "one or more declared outputs per target.",
)
