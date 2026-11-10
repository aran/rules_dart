"""Convenience macro for the freezed builder (produces `<src>.freezed.dart`)."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_codegen")

def freezed_codegen(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        asset_deps = [],
        annotation_dep = "@pub_deps//:freezed_annotation",
        config = "",
        **kwargs):
    """freezed's `<src>.freezed.dart` for each of `srcs`, for their library's `srcs`.

    Args:
      name: The filegroup of the generated files.
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
    library_builder_codegen(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/freezed:shim",
        output_suffixes = [".freezed.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
