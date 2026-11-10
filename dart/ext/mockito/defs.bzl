"""Convenience macro for the mockito builder.

mockito's `@GenerateMocks` typically lives in test files and generates
`<file>.mocks.dart` directly (no SharedPart shards). Any types being
mocked (`MockFoo`) must be in `deps` or `asset_deps` so the Resolver can
read them.
"""

load("@rules_dart//dart/ext:defs.bzl", "library_builder_codegen")

def mockito_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = "@pub_deps//:mockito",
        config = "",
        **kwargs):
    """mockito's `<src>.mocks.dart` for each of `srcs`, for their library's `srcs`.

    Args:
      name: The filegroup of the generated files.
      srcs: `.dart` sources carrying the builder's annotation.
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
        shim = "@rules_dart//dart/ext/mockito:shim",
        output_suffixes = [".mocks.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
