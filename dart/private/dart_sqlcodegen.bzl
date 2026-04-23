"""Code generation from non-Dart input files (drift `.drift` / `.moor`).

Mirrors `dart_codegen` in shape but accepts any file extension on `src`.
Same shim-contract attrs (`package_name`, `deps`, `parts`, `config`,
`package_config`, `generator_args`); same per-file behaviour — one input,
one or more outputs derived by applying each `output_suffixes` entry.

Used to wire SQL-input builders like `drift_dev`'s preparing stage into
the same rules_dart shim contract as Dart-input builders.

Usage:

    load("@rules_dart//dart:defs.bzl", "dart_sqlcodegen")

    dart_sqlcodegen(
        name = "schema_prep",
        src = "schema.drift",
        generator_bin = "@rules_dart//dart/ext/drift:shim_prep",
        output_suffixes = [".drift_prep.json"],
        package_name = "my_app",
        deps = ["@pub_deps//:drift"],
    )
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

def _dart_sqlcodegen_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    sdk_files = toolchain.dart_sdk_info.tool_files

    if not ctx.attr.output_suffixes:
        fail("%s: `output_suffixes` must contain at least one suffix." %
             ctx.label)

    src = ctx.file.src
    synth_pc, lib_dep_srcs = synth_package_config(ctx, ctx.attr.deps)

    lib_root_from_deps = dart_lib_root_for_package(
        ctx.attr.deps,
        ctx.attr.package_name,
    )
    lib_root = lib_root_from_deps if lib_root_from_deps != None else ctx.label.package

    auto_staged, _ = same_package_library_dep_files(
        ctx.attr.deps,
        ctx.attr.package_name,
        exclude_paths = [src.path],
    )

    # Strip the source's actual extension (may be `.drift`, `.moor`, …) and
    # append each output_suffix; place outputs next to the source.
    rel = src.short_path
    if ctx.label.package and rel.startswith(ctx.label.package + "/"):
        rel = rel[len(ctx.label.package) + 1:]
    dot = rel.rfind(".")
    if dot == 0:
        # Dotfile with no stem (e.g. `.drift`). `.<suffix>` makes no sense
        # as an output filename — fail rather than collide or silently
        # produce a weird basename.
        fail(("%s: `src` has no stem before its extension (%r). " +
              "Dart codegen outputs need a non-empty stem.") %
             (ctx.label, src.short_path))
    rel_no_ext = rel[:dot] if dot > 0 else rel
    outputs = [
        ctx.actions.declare_file(rel_no_ext + suffix)
        for suffix in ctx.attr.output_suffixes
    ]

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--input", src.path)
    args.add("--input-asset", asset_path_for(src, lib_root))
    for output in outputs:
        args.add("--output", output.path)

    direct = list(sdk_files) + [src] + list(ctx.files.data)
    direct.extend(add_shim_contract_args(
        args,
        ctx,
        synth_pc,
        auto_stage_srcs = auto_staged,
        asset_deps = ctx.files.asset_deps,
        lib_root = lib_root,
    ))
    args.add_all(ctx.attr.generator_args)

    transitive = [lib_dep_srcs] if lib_dep_srcs != None else []

    ctx.actions.run(
        executable = ctx.executable.generator_bin,
        arguments = [args],
        inputs = depset(direct = direct, transitive = transitive),
        outputs = outputs,
        mnemonic = "DartSqlCodegen",
        progress_message = "DartSqlCodegen %s" % ctx.label,
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
            "worker-key-mnemonic": "DartSqlCodegen",
        },
    )

    return [DefaultInfo(files = depset(outputs))]

dart_sqlcodegen = rule(
    implementation = _dart_sqlcodegen_impl,
    attrs = {
        "src": attr.label(
            doc = "The single non-Dart input file (`.drift`, `.moor`, …).",
            mandatory = True,
            allow_single_file = True,
        ),
        "generator_bin": attr.label(
            doc = "Pre-compiled generator executable matching the " +
                  "rules_dart shim CLI contract.",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "output_suffixes": attr.string_list(
            doc = "Suffixes appended to the source stem (after stripping " +
                  "its extension). E.g. `['.drift_prep.json']`. Multi-" +
                  "output builders (e.g. drift_dev's preparing stage emits " +
                  "both `.drift_prep.json` and `.expr.temp.dart`) declare " +
                  "all suffixes here.",
            mandatory = True,
        ),
        "package_name": attr.string(
            mandatory = True,
            doc = "Dart package name owning `src`. Must match the " +
                  "consuming `dart_library`'s `package_name`.",
        ),
        "language_version": attr.string(
            doc = "Dart language version in `<major>.<minor>` form. " +
                  "Empty falls back to a built-in default.",
        ),
        "deps": attr.label_list(
            doc = "`dart_library`-shaped targets (anything exporting " +
                  "`DartInfo`) whose transitive sources populate a " +
                  "synthesised `package_config.json`. Same-package " +
                  "siblings are auto-staged as `--dep`.",
            providers = [DartInfo],
        ),
        "parts": attr.label_list(
            doc = "Additional input files passed as `--part <path>`.",
            allow_files = True,
        ),
        "config": attr.string(
            doc = "Builder options as a JSON object string.",
        ),
        "package_config": attr.label(
            doc = "Optional pre-existing `package_config.json`; " +
                  "overrides the one synthesised from `deps`.",
            allow_single_file = True,
        ),
        "generator_args": attr.string_list(
            doc = "Escape-hatch additional arguments.",
        ),
        "data": attr.label_list(
            doc = "Additional data files added to action inputs but not " +
                  "passed as flagged args. Sandbox-only — NOT visible to " +
                  "the Builder's `Resolver` / `findAssets`. For files the " +
                  "Builder must see via its AssetReader, use `asset_deps`.",
            allow_files = True,
        ),
        "asset_deps": attr.label_list(
            doc = "Non-Dart files the Builder's `Resolver` / `findAssets` " +
                  "must see. Each file is staged as an action input and " +
                  "passed as `--dep <exec>|<asset>` using `asset_path_for`.",
            allow_files = True,
        ),
    },
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a Dart code generator over a non-Dart input (`.drift`, " +
          "`.moor`, …), producing one or more sibling outputs.",
)
