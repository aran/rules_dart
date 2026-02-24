"""Implementation of the dart_library rule."""

load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")

def _dart_library_impl(ctx):
    # Derive package name
    if ctx.attr.package_name:
        package_name = ctx.attr.package_name
    elif ctx.label.package:
        package_name = ctx.label.package.split("/")[-1]
    else:
        package_name = ctx.label.name

    # Derive the workspace-relative path to the package root directory
    if ctx.label.workspace_root:
        if ctx.label.package:
            lib_root = ctx.label.workspace_root + "/" + ctx.label.package
        else:
            lib_root = ctx.label.workspace_root
    else:
        lib_root = ctx.label.package

    # Collect transitive sources
    transitive_srcs = depset(
        direct = ctx.files.srcs,
        transitive = [dep[DartInfo].transitive_srcs for dep in ctx.attr.deps],
    )

    # Build a DartPackageInfo for this package
    this_pkg = DartPackageInfo(
        package_name = package_name,
        lib_root = lib_root,
    )

    # Collect transitive packages
    transitive_packages = depset(
        direct = [this_pkg],
        transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps],
    )

    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = ctx.runfiles(files = ctx.files.srcs),
        ),
        DartInfo(
            package_name = package_name,
            lib_root = lib_root,
            transitive_srcs = transitive_srcs,
            transitive_packages = transitive_packages,
        ),
    ]

dart_library = rule(
    implementation = _dart_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files for this library.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other dart_library targets this library depends on.",
            providers = [DartInfo],
        ),
        "package_name": attr.string(
            doc = "Override the auto-derived Dart package name.",
        ),
    },
    doc = "Collects Dart sources and propagates dependency information. Does not compile.",
)
