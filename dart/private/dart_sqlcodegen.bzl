"""Code generation from non-Dart input files (drift `.drift` / `.moor`).

Mirrors `dart_codegen` in shape but accepts any file extension on `src`.
Same shim-contract attrs (`package`, `deps`, `parts`, `config`,
`package_config`, `generator_args`); same per-file behaviour — one input,
one or more outputs derived by applying each `output_suffixes` entry.

Used to wire SQL-input builders like `drift_dev`'s preparing stage into
the same rules_dart shim contract as Dart-input builders.

Usage:

    load("@rules_dart//dart:defs.bzl", "dart_sqlcodegen")

    dart_sqlcodegen(
        name = "schema_prep",
        src = "schema.drift",
        generator = "@rules_dart//dart/ext/drift:shim_prep",
        output_suffixes = [".drift_prep.json"],
        package = ":pubspec-metadata",
        deps = ["@pub_deps//:drift"],
    )
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
    "package_identity_attrs",
    "resolve_package_identity",
)
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS")
load("//dart/private:runtime.bzl", "non_dart_transition")

visibility("//dart/...")

def _dart_sqlcodegen_impl(ctx):
    identity = resolve_package_identity(ctx)

    if not ctx.attr.output_suffixes:
        fail("%s: `output_suffixes` must contain at least one suffix." %
             ctx.label)

    src = ctx.file.src
    inputs = codegen_deps(ctx, identity, exclude_paths = [src.path])
    package_root = inputs.package_root

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
    args.add("--input", src)
    args.add("--input-asset", asset_path_for(src, package_root))
    for output in outputs:
        args.add("--output", output)

    direct = [src] + list(ctx.files.data)
    direct.extend(add_shim_contract_args(
        args,
        ctx,
        inputs,
        asset_deps = ctx.files.asset_deps,
    ))
    sdk_files = codegen_sdk_args(args, ctx, inputs.packages)
    args.add_all(ctx.attr.generator_args)

    transitive = ([inputs.package_files] if inputs.package_files != None else []) + [sdk_files]

    ctx.actions.run(
        executable = ctx.executable.generator,
        arguments = [args],
        inputs = depset(direct = direct, transitive = transitive),
        outputs = outputs,
        mnemonic = "DartSqlCodegen",
        exec_group = PORTABLE,
        progress_message = "DartSqlCodegen %s" % ctx.label,
        execution_requirements = PATH_MAPPING | {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
            "worker-key-mnemonic": "DartSqlCodegen",
        },
    )

    return [
        DefaultInfo(files = depset(outputs)),
        # The *effective* values, the SDK's version included: a library stating
        # an older one over a generator that states none is exactly the
        # disagreement `codegen_identity_error` exists to name.
        codegen_identity(identity),
    ] + ([inputs.validation] if inputs.validation else [])

dart_sqlcodegen = rule(
    implementation = _dart_sqlcodegen_impl,
    # Its outputs are the same under every web compiler, whether or not
    # creation locations are tracked and whatever environment the executable
    # above it compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "src": attr.label(
            doc = "The single non-Dart input file (`.drift`, `.moor`, …).",
            mandatory = True,
            allow_single_file = True,
        ),
        "generator": attr.label(
            doc = "The generator: an executable speaking the rules_dart " +
                  "shim contract, persistent-worker protocol included " +
                  "(see `dart_codegen.generator`). Built for the execution " +
                  "platform.",
            executable = True,
            cfg = config.exec(PORTABLE),
            aspects = [codegen_sdk_summary_aspect],
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
        "deps": attr.label_list(
            doc = "`dart_library`-shaped targets (anything exporting " +
                  "`DartInfo`) whose transitive sources populate a " +
                  "synthesised `package_config.json`. Same-package " +
                  "siblings are auto-staged as `--dep`." + CODEGEN_MEMBER_DEPS_DOC,
            providers = CODEGEN_DEP_PROVIDERS,
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
    } | package_identity_attrs() | CODEGEN_DEPS_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Runs a Dart code generator over a non-Dart input (`.drift`, " +
          "`.moor`, …), producing one or more sibling outputs.",
)
