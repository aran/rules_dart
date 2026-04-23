"""Convenience macro for the copy_with_extension_gen builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_library")

def copy_with_library(
        name,
        srcs,
        package_name,
        language_version,
        deps = [],
        annotation_dep = "@pub_deps//:copy_with_extension",
        config = "",
        **kwargs):
    shared_part_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/copy_with_extension_gen:shim",
        part_suffix = ".copy_with_extension_gen.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
