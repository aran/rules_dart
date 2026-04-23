"""Convenience macro for the built_value builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_library")

def built_value_library(
        name,
        srcs,
        package_name,
        language_version,
        deps = [],
        annotation_dep = "@pub_deps//:built_value",
        config = "",
        **kwargs):
    shared_part_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/built_value:shim",
        part_suffix = ".built_value.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
