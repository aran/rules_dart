"""Test-only rule that emits a package stating no language version, in a hand-built `DartInfo`."""

load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")

def _no_lv_dart_library_impl(ctx):
    srcs = ctx.files.srcs
    pkg = DartPackageInfo(
        ctx.label,
        package_name = ctx.attr.package_name,
        package_root = ctx.label.package,
        language_version = "",
    )
    return [
        DefaultInfo(files = depset(srcs)),
        DartInfo(
            packages = (pkg,),
            transitive_srcs = depset(srcs),
            transitive_resources = depset(),
            transitive_packages = depset([pkg]),
        ),
    ]

no_lv_dart_library = rule(
    implementation = _no_lv_dart_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "package_name": attr.string(
            doc = "Dart package name.",
            mandatory = True,
        ),
    },
    doc = "A `dart_library`-shaped rule whose package states no language version.",
)
