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

    # Derive the short_path-based path to the package root directory.
    # For external repos, workspace_root is "external/X" but short_path uses
    # "../X", so we convert to match. For source-tree packages, label.package
    # already matches short_path.
    # Strip trailing /lib since Dart's packageUri: "lib/" is appended to
    # rootUri in package_config.json — rootUri must point to the parent of lib/.
    if ctx.label.workspace_root:
        # Convert "external/X" -> "../X" to match File.short_path convention
        ws_root = ctx.label.workspace_root
        if ws_root.startswith("external/"):
            ws_root = "../" + ws_root[len("external/"):]
        if ctx.label.package:
            lib_root = ws_root + "/" + ctx.label.package
        else:
            lib_root = ws_root
    else:
        lib_root = ctx.label.package
    if lib_root.endswith("/lib") or lib_root == "lib":
        lib_root = lib_root[:-4] if lib_root.endswith("/lib") else ""

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
            doc = "Dart source files (`.dart`) for this library. Typically `glob([\"lib/**/*.dart\"])`.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other `dart_library` targets this library depends on. Their sources and package metadata are propagated transitively.",
            providers = [DartInfo],
        ),
        "package_name": attr.string(
            doc = "The Dart package name used in `package:` imports. If omitted, defaults to the last component of the Bazel package path.",
        ),
    },
    doc = "Collects Dart sources and propagates dependency information via `DartInfo`. Does not compile.",
)
