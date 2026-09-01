"""Convenience macro for the mockito builder.

mockito's `@GenerateMocks` typically lives in test files and generates
`<file>.mocks.dart` directly (no SharedPart shards). Any types being
mocked (`MockFoo`) must live in a `dart_library` passed via `deps` so the
Resolver can read them.
"""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_library")

def mockito_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = "@pub_deps//:mockito",
        config = "",
        **kwargs):
    """A dart_library augmented by mockito codegen."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/mockito:shim",
        output_suffixes = [".mocks.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
