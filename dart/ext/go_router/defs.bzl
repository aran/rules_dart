"""Convenience macro for the go_router_builder builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_library")

def go_router_library(
        name,
        srcs,
        package_name,
        language_version,
        deps = [],
        annotation_dep = "@pub_deps//:go_router",
        config = "",
        **kwargs):
    shared_part_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/go_router:shim",
        part_suffix = ".go_router.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
