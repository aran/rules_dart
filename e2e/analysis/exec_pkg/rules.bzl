"""A downstream rule that is an executable *and* contributes a package.

The shape a `flutter_test` has: the target names a package and its sources are
that package's `lib/` files, plus an entrypoint outside them. Reaching
`DartAnalyzableInfo` through `dart_analyzable_info()` would leave those `lib/`
files in no package record, and every `package:analysis_exec/…` import — the
entrypoint's and the ones the `lib/` files make of each other — would report
`uri_does_not_exist`.

This file is the external-consumer half of that claim: it loads the constructor
from `@rules_dart//dart:utils.bzl` the way a separate rule set does, so the
re-export is exercised rather than assumed.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info_with_package")

def _pkg_executable_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.package_srcs)),
        dart_analyzable_info_with_package(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            package_srcs = ctx.files.package_srcs,
            language_version = ctx.attr.language_version,
        ),
    ]

pkg_executable = rule(
    implementation = _pkg_executable_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Sources outside the package's `lib/` — the entrypoint.",
        ),
        "package_srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "The package's own `lib/` sources.",
        ),
        "deps": attr.label_list(providers = [DartInfo]),
        "package_name": attr.string(mandatory = True),
        "language_version": attr.string(
            doc = "The package's Dart language version, or \"\" when it " +
                  "states none. Present because the real consumer this models " +
                  "has one: the constructor requires an answer, and a rule " +
                  "that cannot supply one from its own attributes would have " +
                  "to invent it.",
        ),
    },
    doc = "An executable contributing a package, analyzable through the " +
          "public constructor rather than a hand-built provider.",
)
