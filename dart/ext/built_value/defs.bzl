"""Convenience macro for the built_value builder."""

load("@rules_dart//dart/ext:defs.bzl", "shared_part_codegen")

def built_value_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = "@pub_deps//:built_value",
        config = "",
        **kwargs):
    """built_value's `<src>.g.dart` for each of `srcs`, for their library's `srcs`.

    Args:
      name: The filegroup of the generated parts.
      srcs: `.dart` sources carrying the builder's annotation.
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
        shim = "@rules_dart//dart/ext/built_value:shim",
        part_suffix = ".built_value.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
