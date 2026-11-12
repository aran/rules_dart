"""A dependency used without an import, as a Flutter plugin is."""

load("//dart:defs.bzl", "dart_library")
load("//dart:providers.bzl", "DartInfo", "DartUsedWithoutImportInfo")

def _used_without_import_impl(ctx):
    library = ctx.attr.library
    return [library[DefaultInfo], library[DartInfo], DartUsedWithoutImportInfo()]

used_without_import = rule(
    implementation = _used_without_import_impl,
    attrs = {"library": attr.label(providers = [DartInfo])},
)

def program_macro(name, **kwargs):
    """A macro whose target takes its `deps` from the call, as `flutter_test`'s `<name>.program` does."""
    dart_library(name = name + ".program", **kwargs)
