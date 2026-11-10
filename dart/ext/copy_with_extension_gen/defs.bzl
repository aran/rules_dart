"""Convenience macro for the copy_with_extension_gen builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_codegen")

def copy_with_codegen(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        asset_deps = [],
        annotation_dep = "@pub_deps//:copy_with_extension",
        config = "",
        **kwargs):
    """copy_with_extension_gen's `<src>.g.dart` for each of `srcs`, for their library's `srcs`.

    Args:
      name: The filegroup of the generated parts.
      srcs: `.dart` sources carrying the builder's annotation.
      package_name: Dart package name; omit when passing `package`.
      language_version: Dart language version; omit when passing `package`.
      deps: The libraries of other packages the sources import.
      asset_deps: The files of the sources' own package they import.
      annotation_dep: The builder's runtime library, added to `deps`.
      config: Builder options as a JSON string, as in `build.yaml`.
      **kwargs: `package`, and the filegroup's `visibility`, `tags`
        and `testonly`.
    """
    shared_part_codegen(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/copy_with_extension_gen:shim",
        part_suffix = ".copy_with_extension_gen.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
