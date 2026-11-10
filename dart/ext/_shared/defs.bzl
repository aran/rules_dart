"""Composable macros used by per-builder `dart/ext/*/defs.bzl` wrappers.

Each writes a builder's codegen targets for some sources and names their
outputs, the files that are parts of those sources' library, under its own
`name`, which the library lists in `srcs`. As build_runner writes `.g.dart`
and similar files beside their library, so the outputs belong to the
library holding the sources, which the macro does not write.

`shared_part_codegen` wires the SharedPart flow: per-src codegen action
emitting a `.<builder>.g.part` shard, and per-src combining action merging
it into `<src>.g.dart`.

`library_builder_codegen` wires a direct-output builder (LibraryBuilder)
that emits `<src>.<ext>.dart` itself (no combining).
"""

load("@rules_dart//dart:defs.bzl", "dart_codegen")

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

def with_annotation_dep(deps, annotation_dep):
    """`deps` with a macro's `annotation_dep`, which they may already list.

    A source that carries an annotation imports its package, so a `deps`
    resolved from the imports (as Gazelle's are) names it already; Bazel
    refuses a label listed twice.

    Args:
      deps: The macro's `deps`.
      annotation_dep: The macro's `annotation_dep`.

    Returns:
      `deps`, with `annotation_dep` appended unless it is there.
    """
    if annotation_dep in deps:
        return deps
    return deps + [annotation_dep]

def visible_files(srcs, src, asset_deps):
    """The files of its package the generator for `src` must see.

    A generator for one file resolves the types it references in the files
    it imports from its own package (`user.dart` naming `Role` from
    `role.dart`): the macro's other sources and its `asset_deps`. They are
    staged as plain files, not through a library: the library holding them
    holds what this generator writes too.

    Args:
      srcs: The macro's `srcs`.
      src: The source one `dart_codegen` runs on.
      asset_deps: The macro's `asset_deps`.

    Returns:
      The labels in `srcs` other than `src`, then `asset_deps`.
    """
    return [s for s in srcs if s != src] + [a for a in asset_deps if a not in srcs]

def outputs_group(name, targets, **kwargs):
    """The filegroup `name` of a macro's outputs, for a library's `srcs`.

    Args:
      name: The macro's `name`.
      targets: The codegen targets whose outputs are parts of the library.
      **kwargs: The macro's common attributes (`visibility`, `tags`,
        `testonly`).
    """
    native.filegroup(name = name, srcs = targets, **kwargs)

def internal_attrs(kwargs):
    """The common attributes a macro's codegen targets take from it.

    A codegen target of a `testonly` macro can depend on what only tests
    may, and is tagged as the macro is.

    Args:
      kwargs: The macro's common attributes.

    Returns:
      A dict of `testonly` and `tags`, those the macro states.
    """
    return {k: kwargs[k] for k in ("testonly", "tags") if k in kwargs}

def shared_part_codegen(
        name,
        srcs,
        shim,
        part_suffix,
        annotation_dep,
        package_name = "",
        language_version = "",
        package = None,
        deps = [],
        asset_deps = [],
        config = "",
        **kwargs):
    """Per-src SharedPart codegen and combining stage, outputs under `name`.

    One `dart_codegen` per src runs the provided shim to produce a
    `.<builder>.g.part` shard; a second `dart_codegen` per src runs the
    combining shim over that shard to produce `<src>.g.dart`. `name` is a
    filegroup of every combined output, which the `dart_library` holding
    `srcs` lists in its own `srcs`.

    Args:
      name: The filegroup of the generated parts.
      srcs: `.dart` source files carrying the builder's annotation.
      package_name: Dart package name (matches consumer pubspec `name:`).
        Omit when passing `package`.
      language_version: Dart language version (`<major>.<minor>`). Omit when
        passing `package`.
      package: A `dart_package_metadata` declaring both of the above once,
        forwarded to every rule this macro emits. Mutually exclusive with the
        two inline arguments — the rules themselves refuse the overlap.
      shim: Label of the per-builder SharedPart shim binary.
      part_suffix: Output extension for the shim (e.g.
        `.json_serializable.g.part`). Exactly one per call.
      annotation_dep: Runtime annotation-library label
        (e.g. `@pub_deps//:json_annotation`).
      deps: The libraries of other packages the sources import;
        `annotation_dep` is added unless they list it.
      asset_deps: The files of the sources' own package that they import,
        directly or through each other, outside `srcs`.
      config: Optional builder options as a JSON string.
      **kwargs: `visibility`, `tags` and `testonly` of the filegroup.
    """
    codegen_deps = with_annotation_dep(deps, annotation_dep)
    common = internal_attrs(kwargs)
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
            package = package,
            deps = codegen_deps,
            asset_deps = visible_files(srcs, src, asset_deps),
            config = config,
            **common
        )
        dart_codegen(
            name = combined_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/_shared/combining_shim:bin",
            output_suffixes = [".g.dart"],
            parts = [":" + part_target],
            package_name = package_name,
            language_version = language_version,
            package = package,
            **common
        )
        combined_targets.append(":" + combined_target)
    outputs_group(name, combined_targets, **kwargs)

def library_builder_codegen(
        name,
        srcs,
        shim,
        output_suffixes,
        annotation_dep,
        package_name = "",
        language_version = "",
        package = None,
        deps = [],
        asset_deps = [],
        config = "",
        **kwargs):
    """Per-src direct-output codegen, outputs under `name`.

    For builders that emit a fully-formed `.dart` file directly
    (LibraryBuilder), not a SharedPart shard. One `dart_codegen` per src;
    `name` is a filegroup of their outputs, which the `dart_library` holding
    `srcs` lists in its own `srcs`.

    Args:
      name: The filegroup of the generated files.
      srcs: `.dart` source files carrying the builder's annotation.
      package_name: Dart package name. Omit when passing `package`.
      language_version: Dart language version (`<major>.<minor>`). Omit when
        passing `package`.
      package: A `dart_package_metadata` declaring both of the above once,
        forwarded to every rule this macro emits. Mutually exclusive with the
        two inline arguments — the rules themselves refuse the overlap.
      shim: Label of the per-builder shim binary.
      output_suffixes: Output file extensions (e.g. `['.freezed.dart']`,
        `['.mocks.dart']`, or several for a builder that emits more than one
        file per input).
      annotation_dep: Runtime annotation-library label.
      deps: The libraries of other packages the sources import;
        `annotation_dep` is added unless they list it.
      asset_deps: The files of the sources' own package that they import,
        directly or through each other, outside `srcs`.
      config: Optional builder options as a JSON string.
      **kwargs: `visibility`, `tags` and `testonly` of the filegroup.
    """
    codegen_deps = with_annotation_dep(deps, annotation_dep)
    common = internal_attrs(kwargs)
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
            package = package,
            deps = codegen_deps,
            asset_deps = visible_files(srcs, src, asset_deps),
            config = config,
            **common
        )
        gen_targets.append(":" + gen_target)
    outputs_group(name, gen_targets, **kwargs)
