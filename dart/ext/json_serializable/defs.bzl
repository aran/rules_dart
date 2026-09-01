"""Convenience macro for the json_serializable builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_library")

def json_serializable_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = "@pub_deps//:json_annotation",
        config = "",
        **kwargs):
    shared_part_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/json_serializable:shim",
        part_suffix = ".json_serializable.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
