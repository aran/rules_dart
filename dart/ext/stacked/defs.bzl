"""Convenience macros for stacked_generator's six LibraryBuilders.

Each macro wires one of stacked_generator's sub-builders (`router`,
`locator`, `form`, `logger`, `dialog`, `bottomsheet`) through the
`library_builder_library` helper. The `@StackedApp` annotation triggers
five of the six (all except `form`, which uses `@FormView`); Gazelle
emits the corresponding macros per registered sub-builder.
"""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_library")

_DEFAULT_RUNTIME_DEP = "@pub_deps//:stacked"

def stacked_router_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """A dart_library augmented by stackedRouterGenerator (`.router.dart`)."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/stacked:shim_router",
        output_suffixes = [".router.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_locator_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """A dart_library augmented by stackedLocatorGenerator (`.locator.dart`)."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/stacked:shim_locator",
        output_suffixes = [".locator.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_form_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """A dart_library augmented by stackedFormGenerator (`.form.dart`)."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/stacked:shim_form",
        output_suffixes = [".form.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_logger_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """A dart_library augmented by stackedLoggerGenerator (`.logger.dart`)."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/stacked:shim_logger",
        output_suffixes = [".logger.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_dialog_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """A dart_library augmented by stackedDialogGenerator (`.dialogs.dart`)."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/stacked:shim_dialog",
        output_suffixes = [".dialogs.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_bottomsheet_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """A dart_library augmented by stackedBottomsheetGenerator (`.bottomsheets.dart`)."""
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/stacked:shim_bottomsheet",
        output_suffixes = [".bottomsheets.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
