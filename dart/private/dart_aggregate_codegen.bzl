"""Package-level aggregate Dart code generation.

Unlike per-file `dart_codegen`, `dart_aggregate_codegen` takes ALL sources
in a Dart package and produces one or more aggregate outputs. Used by
any `PackageBuilder` that needs a whole-package view of metadata.

The generator receives:

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
  - `--sdk-summary <path>` or `--sdk-path <path>`, as `dart_codegen`.

Usage:

    load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen")

    dart_aggregate_codegen(
        name = "di_config",
        srcs = [":metadata_shards"] + SAME_PACKAGE_SOURCES,
        generator = "//tools:my_aggregate_shim",
        outputs = ["lib/main.config.dart", "lib/main.module.dart"],
        deps = ["@pub_deps//:my_annotations"],
        package = ":pubspec-metadata",
    )

`deps` is a list of `dart_library`-shaped targets (anything exporting
`DartInfo`). Their transitive sources populate a synthesised
`package_config.json` for the shim's analyzer; any same-package sibling
not already in `srcs` is auto-staged as `--dep`.

Actions run through a persistent Bazel worker (`supports-workers=1`,
protobuf, singleplex), so the generator must speak that protocol; worker
requests go through `dart/ext/lib/worker_entry.dart`.
"""

load(
    "//dart/private:codegen_deps.bzl",
    "CODEGEN_DEPS_ATTRS",
    "CODEGEN_DEP_PROVIDERS",
    "CODEGEN_MEMBER_DEPS_DOC",
    "codegen_deps",
)
load("//dart/private:codegen_sdk_summary.bzl", "codegen_sdk_args", "codegen_sdk_summary_aspect")
load(
    "//dart/private:common.bzl",
    "PATH_MAPPING",
    "add_shim_contract_args",
    "asset_path_for",
    "codegen_identity",
    "format_literal",
    "package_identity_attrs",
    "resolve_package_identity",
)
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS")
load("//dart/private:runtime.bzl", "non_dart_transition")

visibility("//dart/...")

def _dart_aggregate_codegen_impl(ctx):
    identity = resolve_package_identity(ctx)

    if not ctx.attr.outputs:
        fail("%s: `outputs` must contain at least one path." % ctx.label)
    if not ctx.files.srcs:
        fail("%s: `srcs` cannot be empty." % ctx.label)

    outputs = [ctx.actions.declare_file(path) for path in ctx.attr.outputs]
    src_paths = [s.path for s in ctx.files.srcs]
    inputs = codegen_deps(ctx, identity, exclude_paths = src_paths)
    package_root = inputs.package_root

    args = ctx.actions.args()

    # Worker mode requires a single `@flagfile` arg (`@<path>`, multiline).
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
        inputs,
        asset_deps = ctx.files.asset_deps,
    )
    args.add_all(ctx.attr.generator_args)

    direct_inputs = list(ctx.files.srcs) + extra_inputs
    transitive = [inputs.package_files] if inputs.package_files != None else []

    transitive.append(codegen_sdk_args(args, ctx, inputs.packages))

    ctx.actions.run(
        executable = ctx.executable.generator,
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

    return [
        DefaultInfo(files = depset(outputs)),
        # The *effective* values, the SDK's version included: a library stating
        # an older one over a generator that states none is exactly the
        # disagreement `codegen_identity_error` exists to name.
        codegen_identity(identity),
    ] + ([inputs.validation] if inputs.validation else [])

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
                  "`--dep`." + CODEGEN_MEMBER_DEPS_DOC,
            providers = CODEGEN_DEP_PROVIDERS,
        ),
        "generator": attr.label(
            doc = "The generator: an executable speaking the rules_dart " +
                  "shim contract, persistent-worker protocol included " +
                  "(see `dart_codegen.generator`). Built for the execution " +
                  "platform.",
            mandatory = True,
            executable = True,
            cfg = config.exec(PORTABLE),
            aspects = [codegen_sdk_summary_aspect],
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
    } | package_identity_attrs() | CODEGEN_DEPS_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Runs a package-level aggregate Dart code generator, producing " +
          "one or more declared outputs per target.",
)
