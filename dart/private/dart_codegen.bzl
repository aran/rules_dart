"""Per-file Dart code generation.

Runs a `package:build` Builder (via the rules_dart shim runner) over a
single Dart source file, producing one or more sibling output files whose
paths derive from the input's stem + each entry in `output_suffixes`.

The generator receives:

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
  - `--sdk-summary <path>`: the summary of the Dart SDK the generator wrote
    itself, for a generator built on the shim runner; or `--sdk-path <path>`,
    the SDK's root, when a `sky_engine` is among the packages (see
    `docs/ext.md`). A generator not built on the shim runner gets neither.
  - Anything in `generator_args` (escape hatch — prefer the typed attrs).

Usage:

    load("@rules_dart//dart:defs.bzl", "dart_codegen")

    dart_codegen(
        name = "user_g",
        src = "lib/user.dart",
        generator = "@rules_dart//dart/ext/json_serializable:shim",
        output_suffixes = [".json_serializable.g.part"],
        package = ":pubspec-metadata",
        deps = [
            ":models",                          # same-package sibling
            "@pub_deps//:json_annotation",      # import source
        ],
    )

`deps` is a list of `dart_library`-shaped targets (anything exporting
`DartInfo`). Their transitive sources populate a `package_config.json`
so `package:` imports resolve; any of their files under the `lib/` of the
Dart package `src` belongs to is also auto-staged as `--dep` so the Resolver
can walk sibling files without the caller listing them explicitly.

The generated files can be used as srcs in a downstream `dart_library`.

Actions run through a persistent Bazel worker (singleplex, protobuf
protocol) via `dart/ext/lib/worker_entry.dart` + `package:bazel_worker`,
so the generator must speak that protocol. The analyzer driver is fresh per request —
reusing across requests is a silent-corruption hazard due to
`source_gen`'s CWD-pinned `rootPackageName` — but the Dart VM startup
cost is amortised across the worker's lifetime.
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
    identity = resolve_package_identity(ctx)

    if not ctx.attr.output_suffixes:
        fail("%s: `output_suffixes` must contain at least one suffix." %
             ctx.label)

    src = ctx.file.src
    inputs = codegen_deps(ctx, identity, exclude_paths = [src.path])
    package_root = inputs.package_root

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

    # Worker mode requires a single `@flagfile` / `--flagfile=` arg; the
    # `use_param_file` + `multiline` format produces exactly that and
    # Bazel expands it into `WorkRequest.arguments` on the transport.
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--input", src)
    args.add("--input-asset", asset_path_for(src, package_root))
    for output in outputs:
        args.add("--output", output)
    direct_inputs.extend(add_shim_contract_args(
        args,
        ctx,
        inputs,
        asset_deps = ctx.files.asset_deps,
    ))
    sdk_files = codegen_sdk_args(args, ctx, inputs.packages)
    args.add_all(ctx.attr.generator_args)

    ctx.actions.run(
        executable = ctx.executable.generator,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = _transitive(inputs.package_files) + [sdk_files],
        ),
        outputs = outputs,
        mnemonic = "DartCodegen",
        exec_group = PORTABLE,
        progress_message = "DartCodegen %s" % ctx.label,
        execution_requirements = PATH_MAPPING | {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
            # The worker key includes the generator's path; using the
            # same mnemonic across builders still yields distinct worker
            # pools because Bazel keys on `(mnemonic, binary)`.
            "worker-key-mnemonic": "DartCodegen",
        },
    )

    return [
        DefaultInfo(files = depset(outputs)),
        # The *effective* values, the SDK's version included: a library stating
        # an older one over a generator that states none is exactly the
        # disagreement `codegen_identity_error` exists to name.
        codegen_identity(identity),
    ] + ([inputs.validation] if inputs.validation else [])

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
    # Its outputs are the same under every web compiler, whether or not
    # creation locations are tracked and whatever environment the executable
    # above it compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "src": attr.label(
            doc = "The single `.dart` input file to process. Use one " +
                  "`dart_codegen` target per input.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "generator": attr.label(
            doc = "The generator: an executable speaking the rules_dart " +
                  "shim contract, persistent-worker protocol included, " +
                  "such as a `dart_binary` whose `main` calls `shimMain` " +
                  "from `package:rules_dart_ext/worker_entry.dart` with a " +
                  "`package:build` Builder. Built for the execution platform.",
            mandatory = True,
            executable = True,
            cfg = config.exec(PORTABLE),
            aspects = [codegen_sdk_summary_aspect],
        ),
        "output_suffixes": attr.string_list(
            doc = "One or more suffixes appended to the input stem to " +
                  "derive output file paths. E.g. `['.g.dart']` for a " +
                  "SharedPart combining output; `['.dart.drift_module.json', " +
                  "'.dart.types.temp.dart']` for a builder that " +
                  "emits both per input (drift's analyzer). At least one " +
                  "suffix is required.",
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "`dart_library`-shaped targets (anything exporting " +
                  "`DartInfo`) whose transitive sources populate a " +
                  "synthesised `package_config.json` for the shim's " +
                  "analyzer. Any of their files under the `lib/` of " +
                  "`src`'s Dart package is also auto-staged as `--dep` so " +
                  "the Resolver can walk siblings." + CODEGEN_MEMBER_DEPS_DOC,
            providers = CODEGEN_DEP_PROVIDERS,
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
            doc = "Files the Builder's `Resolver` / `findAssets` must " +
                  "see that no library in `deps` holds: non-Dart files " +
                  "(e.g. `.drift` schemas, `.drift_prep.json` " +
                  "sidecars, `.yaml` configs read via `BuildStep`). Each " +
                  "file is staged as an action input and passed as " +
                  "`--dep <exec>|<asset>` using `asset_path_for`. Dart " +
                  "sources of the package that no library can hold yet " +
                  "go here too: a macro's other sources, or an earlier " +
                  "stage's output, before the parts generated for them " +
                  "exist. For Dart libraries, use `deps`. For files that only need " +
                  "to exist on disk for a subprocess / runfile (not read " +
                  "through `package:build`), use `data`.",
            allow_files = True,
        ),
    } | package_identity_attrs() | CODEGEN_DEPS_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Runs a per-file Dart code generator, producing one or more " +
          "sibling outputs per input.",
)
