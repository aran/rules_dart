"""Test-only rule that emits `DartPackageInfo` without `language_version`."""

load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")

def _no_lv_dart_library_impl(ctx):
    srcs = ctx.files.srcs
    pkg = DartPackageInfo(
        package_name = ctx.attr.package_name,
        lib_root = ctx.label.package,
        # `language_version` omitted.
    )
    return [
        DefaultInfo(files = depset(srcs)),
        DartInfo(
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            transitive_srcs = depset(srcs),
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
    doc = "A `dart_library`-shaped rule that emits `DartPackageInfo` without `language_version`.",
)
