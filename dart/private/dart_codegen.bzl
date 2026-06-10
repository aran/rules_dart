"""Per-file Dart code generation.

Runs a `package:build` Builder (via the rules_dart shim runner) over a
single Dart source file, producing one or more sibling output files whose
paths derive from the input's stem + each entry in `output_suffixes`.

The generator (`generator` script or `generator_bin` binary) receives:

  - `--input <path>`: the input source file's exec-root path.
  - `--input-asset <asset>`: the input's Dart asset path, relative to the
    owning Dart package (e.g. `lib/src/models/user.dart`).
  - `--output <path>` (repeatable): one per `output_suffixes` entry.
  - `--package <name>`: the Dart package name owning the input.
  - `--dep <exec>|<asset>` (repeatable): one per same-package sibling file
    auto-staged from `deps`. The shim mounts each entry so the Builder's
    Resolver / `findAssets` / `readAsString` see it.
  - `--part <path>` (repeatable): one per `parts` entry, for the combining
    shim merging `.<builder>.g.part` shards into a final `.g.dart`.
  - `--config <json>`: builder options as a JSON object string.
  - `--package-config <path>`: a `package_config.json` synthesised from
    `deps`' transitive Dart packages. Overridden by the user-supplied
    `package_config` attr when set.
  - `--root-language-version <major.minor>`: the consuming package's Dart
    language version (propagated through the synthesised PackageConfig).
  - `--sdk-path <path>`: the Dart SDK root (the analyzer's AOT shim can't
    auto-detect it).
  - Anything in `generator_args` (escape hatch — prefer the typed attrs).

Usage:

    load("@rules_dart//dart:defs.bzl", "dart_codegen")

    dart_codegen(
        name = "user_g",
        src = "lib/user.dart",
        generator_bin = "@rules_dart//dart/ext/json_serializable:shim",
        output_suffixes = [".json_serializable.g.part"],
        package_name = "my_pkg",
        deps = [
            ":models",                          # same-package sibling
            "@pub_deps//:json_annotation",      # import source
        ],
    )

`deps` is a list of `dart_library`-shaped targets (anything exporting
`DartInfo`). Their transitive sources populate a `package_config.json`
so `package:` imports resolve; any file that belongs to the *same* Dart
package as `src` is also auto-staged as `--dep` so the Resolver can walk
sibling files without the caller listing them explicitly.

The generated files can be used as srcs in a downstream `dart_library`.

When `generator_bin` is set, actions run through a persistent Bazel worker
(singleplex, protobuf protocol) via `dart/ext/lib/worker_entry.dart` +
`package:bazel_worker`. The analyzer driver is fresh per request —
reusing across requests is a silent-corruption hazard due to
`source_gen`'s CWD-pinned `rootPackageName` — but the Dart VM startup
cost is amortised across the worker's lifetime.
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

def compute_codegen_output_name(src_path, output_suffix):
    """Compute the output file path for a codegen source file.

    Replaces the trailing `.dart` extension with `output_suffix`.

    Args:
        src_path: Source file path (e.g. `some/dir/model.dart`).
        output_suffix: Suffix to append after stripping `.dart` (e.g. `.g.dart`).

    Returns:
        The output file path (e.g. `some/dir/model.g.dart`).
    """
    if src_path.endswith(".dart"):
        base = src_path[:-len(".dart")]
    else:
        base = src_path
    return base + output_suffix

def _dart_codegen_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart = toolchain.dart_sdk_info.dart
    sdk_files = toolchain.dart_sdk_info.tool_files

    if ctx.file.generator and ctx.executable.generator_bin:
        fail("%s: only one of `generator` or `generator_bin` may be set." %
             ctx.label)
    if not ctx.file.generator and not ctx.executable.generator_bin:
        fail("%s: either `generator` or `generator_bin` must be set." %
             ctx.label)
    if not ctx.attr.output_suffixes:
        fail("%s: `output_suffixes` must contain at least one suffix." %
             ctx.label)

    src = ctx.file.src
    synth_pc, library_dep_srcs = synth_package_config(ctx, ctx.attr.deps)

    # Derive the Dart package's lib_root from deps' DartInfo — works even
    # when the codegen rule's Bazel package path doesn't match the Dart
    # package root (e.g. `//myapp/lib:codegen` for Dart package `myapp`).
    lib_root_from_deps = dart_lib_root_for_package(
        ctx.attr.deps,
        ctx.attr.package_name,
    )
    lib_root = lib_root_from_deps if lib_root_from_deps != None else ctx.label.package

    # Auto-stage same-package sibling files discovered in `deps` so builders
    # (stacked, mockito, cross-file resolvers, …) see them via the Resolver /
    # `findAssets` / `readAsString` without users hand-listing every file.
    auto_staged, _ = same_package_library_dep_files(
        ctx.attr.deps,
        ctx.attr.package_name,
        exclude_paths = [src.path],
    )

    # Place each output next to the source. declare_file paths are package-
    # relative, so compute a package-relative stem by stripping the Bazel
    # package prefix from src.short_path.
    rel = src.short_path
    if ctx.label.package and rel.startswith(ctx.label.package + "/"):
        rel = rel[len(ctx.label.package) + 1:]
    rel_no_ext = rel[:-len(".dart")] if rel.endswith(".dart") else rel
    outputs = [
        ctx.actions.declare_file(rel_no_ext + suffix)
        for suffix in ctx.attr.output_suffixes
    ]

    args = ctx.actions.args()
    direct_inputs = [src] + list(ctx.files.data)

    if ctx.executable.generator_bin:
        # Worker mode requires a single `@flagfile` / `--flagfile=` arg; the
        # `use_param_file` + `multiline` format produces exactly that and
        # Bazel expands it into `WorkRequest.arguments` on the transport.
        args.use_param_file("@%s", use_always = True)
        args.set_param_file_format("multiline")
        args.add("--input", src.path)
        args.add("--input-asset", asset_path_for(src, lib_root))
        for output in outputs:
            args.add("--output", output.path)
        direct_inputs.extend(add_shim_contract_args(
            args,
            ctx,
            synth_pc,
            auto_stage_srcs = auto_staged,
            asset_deps = ctx.files.asset_deps,
            lib_root = lib_root,
        ))
        args.add_all(ctx.attr.generator_args)

        ctx.actions.run(
            executable = ctx.executable.generator_bin,
            arguments = [args],
            inputs = depset(
                direct = direct_inputs,
                transitive = _transitive(library_dep_srcs) + [sdk_files],
            ),
            outputs = outputs,
            mnemonic = "DartCodegen",
            progress_message = "DartCodegen %s" % ctx.label,
            execution_requirements = {
                "supports-workers": "1",
                "requires-worker-protocol": "proto",
                # The worker key includes the shim binary path; using the
                # same mnemonic across builders still yields distinct worker
                # pools because Bazel keys on `(mnemonic, binary)`.
                "worker-key-mnemonic": "DartCodegen",
            },
        )
    else:
        # Run generator as a Dart script via the SDK's dart executable.
        args.add(ctx.file.generator.path)
        args.add("--input", src.path)
        args.add("--input-asset", asset_path_for(src, lib_root))
        for output in outputs:
            args.add("--output", output.path)
        direct_inputs.extend(add_shim_contract_args(
            args,
            ctx,
            synth_pc,
            auto_stage_srcs = auto_staged,
            asset_deps = ctx.files.asset_deps,
            lib_root = lib_root,
        ))
        args.add_all(ctx.attr.generator_args)
        direct_inputs.append(ctx.file.generator)

        ctx.actions.run(
            executable = dart,
            arguments = [args],
            inputs = depset(
                direct = direct_inputs,
                transitive = _transitive(library_dep_srcs) + [sdk_files],
            ),
            outputs = outputs,
            mnemonic = "DartCodegen",
            progress_message = "DartCodegen %s" % ctx.label,
        )

    return [DefaultInfo(files = depset(outputs))]

def _transitive(d):
    """Wraps an optional depset as a single-element list for `depset(transitive=...)`.

    Returns an empty list when `d` is `None` (which `synth_package_config`
    returns when `deps` is empty).

    Args:
      d: An optional depset, or `None`.

    Returns:
      `[d]` if `d` is non-`None`, otherwise `[]`.
    """
    return [d] if d != None else []

dart_codegen = rule(
    implementation = _dart_codegen_impl,
    attrs = {
        "src": attr.label(
            doc = "The single `.dart` input file to process. Use one " +
                  "`dart_codegen` target per input.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "generator": attr.label(
            doc = "A `.dart` script to run as the code generator. " +
                  "Mutually exclusive with `generator_bin`.",
            allow_single_file = [".dart"],
        ),
        "generator_bin": attr.label(
            doc = "A pre-compiled generator executable matching the " +
                  "rules_dart shim CLI contract. Mutually exclusive with " +
                  "`generator`.",
            executable = True,
            cfg = "exec",
        ),
        "output_suffixes": attr.string_list(
            doc = "One or more suffixes appended to the input stem to " +
                  "derive output file paths. E.g. `['.g.dart']` for a " +
                  "SharedPart combining output; `['.config.dart', " +
                  "'.module.dart']` for injectable's config stage, which " +
                  "emits both per input. At least one suffix is required.",
            mandatory = True,
        ),
        "package_name": attr.string(
            mandatory = True,
            doc = "Dart package name owning `src`. Must match the " +
                  "consuming `dart_library`'s `package_name`. Passed as " +
                  "`--package`.",
        ),
        "language_version": attr.string(
            doc = "Dart language version of the consuming package, in " +
                  "`<major>.<minor>` form (e.g. `3.11`). When empty, " +
                  "defers to a built-in safe default — set explicitly " +
                  "only when pinning to a specific language-version " +
                  "behaviour.",
        ),
        "deps": attr.label_list(
            doc = "`dart_library`-shaped targets (anything exporting " +
                  "`DartInfo`) whose transitive sources populate a " +
                  "synthesised `package_config.json` for the shim's " +
                  "analyzer. Any file belonging to the same Dart package " +
                  "as `src` is also auto-staged as `--dep` so the " +
                  "Resolver can walk siblings.",
            providers = [DartInfo],
        ),
        "parts": attr.label_list(
            doc = "Additional input files passed as `--part <path>` " +
                  "(used by the combining shim to merge SharedPart shards).",
            allow_files = True,
        ),
        "config": attr.string(
            doc = "Builder options as a JSON object string. Passed as " +
                  "`--config <json>`. Shape mirrors build_runner's " +
                  "`build.yaml` `options:` block for the underlying builder.",
        ),
        "package_config": attr.label(
            doc = "Optional pre-existing `package_config.json` passed as " +
                  "`--package-config <path>`. When unset the rule " +
                  "synthesises one from `deps`.",
            allow_single_file = True,
        ),
        "generator_args": attr.string_list(
            doc = "Escape-hatch additional arguments. Prefer the typed " +
                  "attrs above.",
        ),
        "data": attr.label_list(
            doc = "Additional data files added to the action inputs but " +
                  "not passed as flagged args. Sandbox-only — NOT visible " +
                  "to the Builder's `Resolver` / `findAssets`. For files " +
                  "the Builder must see via its AssetReader, use " +
                  "`asset_deps` instead.",
            allow_files = True,
        ),
        "asset_deps": attr.label_list(
            doc = "Non-Dart files the Builder's `Resolver` / `findAssets` " +
                  "must see (e.g. `.drift` schemas, `.drift_prep.json` " +
                  "sidecars, `.yaml` configs read via `BuildStep`). Each " +
                  "file is staged as an action input and passed as " +
                  "`--dep <exec>|<asset>` using `asset_path_for`. For " +
                  "Dart libraries, use `deps`. For files that only need " +
                  "to exist on disk for a subprocess / runfile (not read " +
                  "through `package:build`), use `data`.",
            allow_files = True,
        ),
    },
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a per-file Dart code generator, producing one or more " +
          "sibling outputs per input.",
)
