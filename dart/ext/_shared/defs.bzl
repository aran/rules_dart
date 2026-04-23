"""Composable macros used by per-builder `dart/ext/*/defs.bzl` wrappers.

`shared_part_library` wires the full SharedPart flow: per-src codegen
action emitting a `.<builder>.g.part` shard, per-src combining action
merging any matching shards into `<src>.g.dart`, and a wrapping
`dart_library` that picks up the combined outputs alongside the user's
`srcs`.

`library_builder_library` wires a direct-output builder (LibraryBuilder)
that emits `<src>.<ext>.dart` straight into the source tree (no combining).
"""

load("@rules_dart//dart:defs.bzl", "dart_codegen", "dart_library")

def _src_token(src_label):
    """Reduce a Bazel label / filename to a valid target-name token.

    Strips `//`, splits at `:`, then replaces `/`, `.`, and `-` with `_`.
    E.g. `lib/src/models/user.dart` → `lib_src_models_user_dart`.
    """
    s = src_label
    if s.startswith("//"):
        s = s[2:]
    if ":" in s:
        s = s.split(":")[-1]
    return s.replace("/", "_").replace(".", "_").replace("-", "_")

def shared_part_library(
        name,
        srcs,
        package_name,
        language_version,
        shim,
        part_suffix,
        annotation_dep,
        deps = [],
        config = "",
        **kwargs):
    """Compose per-src SharedPart codegen + combining stage + wrapping dart_library.

    One `dart_codegen` per src runs the provided shim to produce a
    `.<builder>.g.part` shard; a second `dart_codegen` per src runs the
    combining shim over that shard (plus any other `part_suffix` shards
    wired by the caller via Gazelle's DAG synthesis) to produce a single
    `<src>.g.dart`. The wrapping `dart_library` then includes every
    per-src combined output alongside the user's original `srcs`.

    Args:
      name: Wrapping `dart_library` target name.
      srcs: `.dart` source files carrying the builder's annotation.
      package_name: Dart package name (matches consumer pubspec `name:`).
      language_version: Dart language version (`<major>.<minor>`).
      shim: Label of the per-builder SharedPart shim binary.
      part_suffix: Output extension for the shim (e.g.
        `.json_serializable.g.part`). Exactly one per call.
      annotation_dep: Runtime annotation-library label
        (e.g. `@pub_deps//:json_annotation`).
      deps: Additional `dart_library`-shaped targets; `annotation_dep` is
        added automatically.
      config: Optional builder options as a JSON string.
      **kwargs: Forwarded to the wrapping `dart_library` (which also
        receives `language_version`).
    """
    combined_targets = []
    for src in srcs:
        token = _src_token(src)
        part_target = "_{name}_{token}_part".format(name = name, token = token)
        combined_target = "_{name}_{token}_combined".format(
            name = name,
            token = token,
        )
        dart_codegen(
            name = part_target,
            src = src,
            generator_bin = shim,
            output_suffixes = [part_suffix],
            package_name = package_name,
            language_version = language_version,
            deps = deps + [annotation_dep],
            config = config,
        )
        dart_codegen(
            name = combined_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/_shared/combining_shim:bin",
            output_suffixes = [".g.dart"],
            parts = [":" + part_target],
            package_name = package_name,
            language_version = language_version,
        )
        combined_targets.append(":" + combined_target)
    dart_library(
        name = name,
        srcs = srcs + combined_targets,
        deps = deps + [annotation_dep],
        package_name = package_name,
        language_version = language_version,
        **kwargs
    )

def library_builder_library(
        name,
        srcs,
        package_name,
        language_version,
        shim,
        output_suffixes,
        annotation_dep,
        deps = [],
        config = "",
        **kwargs):
    """Compose per-src direct-output codegen + wrapping dart_library.

    For builders that emit a fully-formed `.dart` library directly
    (LibraryBuilder), not a SharedPart shard. One `dart_codegen` per src,
    then a wrapping `dart_library`.

    Args:
      name: Wrapping `dart_library` target name.
      srcs: `.dart` source files carrying the builder's annotation.
      package_name: Dart package name.
      language_version: Dart language version (`<major>.<minor>`).
      shim: Label of the per-builder shim binary.
      output_suffixes: Output file extensions (e.g. `['.freezed.dart']`,
        `['.mocks.dart']`, or multi-output like `['.config.dart',
        '.module.dart']` for builders that emit more than one file
        per input).
      annotation_dep: Runtime annotation-library label.
      deps: Additional `dart_library`-shaped targets; `annotation_dep`
        is added automatically.
      config: Optional builder options as a JSON string.
      **kwargs: Forwarded to the wrapping `dart_library`.
    """
    gen_targets = []
    for src in srcs:
        token = _src_token(src)
        gen_target = "_{name}_{token}_gen".format(name = name, token = token)
        dart_codegen(
            name = gen_target,
            src = src,
            generator_bin = shim,
            output_suffixes = output_suffixes,
            package_name = package_name,
            language_version = language_version,
            deps = deps + [annotation_dep],
            config = config,
        )
        gen_targets.append(":" + gen_target)
    dart_library(
        name = name,
        srcs = srcs + gen_targets,
        deps = deps + [annotation_dep],
        package_name = package_name,
        language_version = language_version,
        **kwargs
    )
