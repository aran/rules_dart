"""The fixture builder's macro, as another rule set writes one."""

load("@rules_dart//dart/ext:defs.bzl", "shared_part_codegen")

def greeting_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = Label("//builders/external_builder/annotation:greeting"),
        config = "",
        **kwargs):
    """The greeting builder's `<src>.g.dart` for each of `srcs`, for their library's `srcs`.

    Args:
      name: The filegroup of the generated parts.
      srcs: `.dart` sources carrying `@Greeting`.
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
        shim = Label("//builders/external_builder/builder:shim"),
        part_suffix = ".greeting.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
