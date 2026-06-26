"""Package-level aggregate Dart code generation.

Unlike per-file `dart_codegen`, `dart_aggregate_codegen` takes ALL sources
in a Dart package and produces one or more aggregate outputs. Used by
builders like `injectable_generator`'s config stage (DI container +
optional modules) and any `PackageBuilder` that needs a whole-package
view of metadata.

The generator (`generator` binary or `generator_script`) receives:

  - `--input <path>`: the primary input (first entry in `srcs`).
  - `--input-asset <asset>`: the primary's Dart asset path.
  - `--input-asset-extra <exec>|<asset>` (repeatable): one per additional
    source in `srcs`. Exposed to the Builder as primary asset inputs.
  - `--output <path>` (repeatable): one per `outputs` entry. Multi-output
    aggregates (e.g. injectable config emitting both `.config.dart` and
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
        generator_bin = "@rules_dart//dart/ext/injectable:shim_config",
        outputs = ["lib/main.config.dart", "lib/main.module.dart"],
        deps = ["@pub_deps//:injectable"],
        package_name = "my_app",
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
    "add_shim_contract_args",
    "asset_path_for",
    "dart_lib_root_for_package",
    "same_package_library_dep_files",
    "synth_package_config",
)

def _dart_aggregate_codegen_impl(ctx):
    toolchain = ctx.toolchains["//dart:exec_tools_toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

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
    synth_pc, transitive_srcs = synth_package_config(ctx, ctx.attr.deps)

    lib_root_from_deps = dart_lib_root_for_package(
        ctx.attr.deps,
        ctx.attr.package_name,
    )
    lib_root = lib_root_from_deps if lib_root_from_deps != None else ctx.label.package

    src_paths = [s.path for s in ctx.files.srcs]
    auto_staged, _ = same_package_library_dep_files(
        ctx.attr.deps,
        ctx.attr.package_name,
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
    args.add("--input", primary.path)
    args.add("--input-asset", asset_path_for(primary, lib_root))
    for output in outputs:
        args.add("--output", output.path)
    for src in ctx.files.srcs[1:]:
        args.add(
            "--input-asset-extra",
            "{}|{}".format(src.path, asset_path_for(src, lib_root)),
        )
    extra_inputs = add_shim_contract_args(
        args,
        ctx,
        synth_pc,
        dart_sdk_info.dart,
        auto_stage_srcs = auto_staged,
        asset_deps = ctx.files.asset_deps,
        lib_root = lib_root,
    )
    args.add_all(ctx.attr.generator_args)

    direct_inputs = list(ctx.files.srcs) + extra_inputs
    transitive = [transitive_srcs] if transitive_srcs != None else []
    transitive.append(dart_sdk_info.tool_files)

    if ctx.executable.generator_bin:
        ctx.actions.run(
            executable = ctx.executable.generator_bin,
            arguments = [args],
            inputs = depset(direct = direct_inputs, transitive = transitive),
            outputs = outputs,
            mnemonic = "DartAggregateCodegen",
            progress_message = "DartAggregateCodegen %s" % ctx.label,
            execution_requirements = {
                "supports-workers": "1",
                "requires-worker-protocol": "proto",
                "worker-key-mnemonic": "DartAggregateCodegen",
            },
        )
    else:
        ctx.actions.run(
            executable = dart_sdk_info.dart,
            arguments = [ctx.file.generator_script.path, args],
            inputs = depset(
                direct = [ctx.file.generator_script] + direct_inputs,
                transitive = transitive,
            ),
            outputs = outputs,
            mnemonic = "DartAggregateCodegen",
            progress_message = "DartAggregateCodegen %s" % ctx.label,
        )

    return [DefaultInfo(files = depset(outputs))]

dart_aggregate_codegen = rule(
    implementation = _dart_aggregate_codegen_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "All source files the builder analyses. The first " +
                  "entry is the primary input passed as `--input` (its " +
                  "extension must match one in the builder's " +
                  "`buildExtensions` map); the rest are passed as " +
                  "`--input-asset-extra` and staged so the Builder's " +
                  "`findAssets` / `readAsString` see them. Typically a " +
                  "mix of `.dart` source files and generated data shards " +
                  "(e.g. `.injectable.json` for the injectable aggregate).",
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
            cfg = "exec",
        ),
        "generator_script": attr.label(
            doc = "A `.dart` script to run via `dart run` as the " +
                  "generator. Mutually exclusive with `generator`.",
            allow_single_file = [".dart"],
        ),
        "outputs": attr.string_list(
            doc = "Output file paths (package-relative). One entry per " +
                  "builder-produced extension — e.g. `['lib/app.config.dart', " +
                  "'lib/app.module.dart']` for injectable's config stage.",
            mandatory = True,
        ),
        "package_name": attr.string(
            mandatory = True,
            doc = "Dart package name owning `srcs`. Must match the " +
                  "consuming `dart_library`'s `package_name`.",
        ),
        "language_version": attr.string(
            doc = "Dart language version of the consuming package, in " +
                  "`<major>.<minor>` form. Empty falls back to a " +
                  "built-in default.",
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
    },
    toolchains = ["//dart:exec_tools_toolchain_type"],
    doc = "Runs a package-level aggregate Dart code generator, producing " +
          "one or more declared outputs per target.",
)
