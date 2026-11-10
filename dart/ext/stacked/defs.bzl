"""Convenience macros for stacked_generator's six LibraryBuilders.

Each macro wires one of stacked_generator's sub-builders (`router`,
`locator`, `form`, `logger`, `dialog`, `bottomsheet`) through the
`library_builder_codegen` helper. The `@StackedApp` annotation triggers
five of the six (all except `form`, which uses `@FormView`).
"""

load("@rules_dart//dart/ext:defs.bzl", "library_builder_codegen")

_DEFAULT_RUNTIME_DEP = "@pub_deps//:stacked"

def stacked_router_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """stackedRouterGenerator's `<src>.router.dart` for each of `srcs`, for their library's `srcs`.

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
        shim = "@rules_dart//dart/ext/stacked:shim_router",
        output_suffixes = [".router.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )

def stacked_locator_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """stackedLocatorGenerator's `<src>.locator.dart` for each of `srcs`, for their library's `srcs`.

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
        shim = "@rules_dart//dart/ext/stacked:shim_locator",
        output_suffixes = [".locator.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )

def stacked_form_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """stackedFormGenerator's `<src>.form.dart` for each of `srcs`, for their library's `srcs`.

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
        shim = "@rules_dart//dart/ext/stacked:shim_form",
        output_suffixes = [".form.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )

def stacked_logger_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """stackedLoggerGenerator's `<src>.logger.dart` for each of `srcs`, for their library's `srcs`.

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
        shim = "@rules_dart//dart/ext/stacked:shim_logger",
        output_suffixes = [".logger.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )

def stacked_dialog_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """stackedDialogGenerator's `<src>.dialogs.dart` for each of `srcs`, for their library's `srcs`.

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
        shim = "@rules_dart//dart/ext/stacked:shim_dialog",
        output_suffixes = [".dialogs.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )

def stacked_bottomsheet_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """stackedBottomsheetGenerator's `<src>.bottomsheets.dart` for each of `srcs`, for their library's `srcs`.

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
        shim = "@rules_dart//dart/ext/stacked:shim_bottomsheet",
        output_suffixes = [".bottomsheets.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
