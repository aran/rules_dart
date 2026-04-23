"""Convenience macro for the freezed builder (produces `<src>.freezed.dart`)."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_library")

def freezed_library(
        name,
        srcs,
        package_name,
        language_version,
        deps = [],
        annotation_dep = "@pub_deps//:freezed_annotation",
        config = "",
        **kwargs):
    """A dart_library whose sources are augmented by freezed codegen."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/freezed:shim",
        output_suffixes = [".freezed.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
