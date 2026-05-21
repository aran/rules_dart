"""Implementation of the dart_library rule."""

load("@bazel_lib//lib:copy_to_bin.bzl", "COPY_FILE_TO_BIN_TOOLCHAINS", "copy_files_to_bin_actions")
load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load("//dart/private:common.bzl", "is_mixed_package")

def derive_package_name(package_name_attr, label_package, label_name):
    """Derive the Dart package name from rule attributes and label.

    Args:
        package_name_attr: Explicit package name attribute, or empty string.
        label_package: The Bazel label package path.
        label_name: The Bazel label name.

    Returns:
        The derived Dart package name.
    """
    if package_name_attr:
        return package_name_attr
    elif label_package:
        return label_package.split("/")[-1]
    else:
        return label_name

def check_no_duplicate_srcs(label, srcs):
    """Detects two `srcs` entries that resolve to the same package-relative path.

    Typically fires when a stale `build_runner`-generated file is listed in
    the source tree alongside a codegen target producing the same output.

    Args:
      label: The owning rule's label (included in the error message).
      srcs: The `srcs` list to inspect.

    Returns:
      An error message string if a collision is found, or `None` otherwise.
    """
    seen = {}
    for src in srcs:
        prev = seen.get(src.short_path)
        if prev != None and prev != src.path:
            return (
                ("%s: `srcs` contains two files that resolve to the same " +
                 "package-relative path `%s` — typically a stale " +
                 "`build_runner`-generated file in the source tree listed " +
                 "alongside a codegen target producing the same output. " +
                 "First: %s. Second: %s.") % (label, src.short_path, prev, src.path)
            )
        seen[src.short_path] = src.path
    return None

def derive_lib_root(workspace_root, label_package):
    """Derive the library root path (short_path-based, without /lib suffix).

    For external repos, converts "external/X" to "../X" to match
    File.short_path convention. Strips trailing /lib since Dart's
    packageUri: "lib/" is appended to rootUri in package_config.json.

    Args:
        workspace_root: The workspace root of the label (ctx.label.workspace_root).
        label_package: The Bazel label package path (ctx.label.package).

    Returns:
        The library root path with any trailing /lib stripped.
    """
    if workspace_root:
        # Convert "external/X" -> "../X" to match File.short_path convention
        ws_root = workspace_root
        if ws_root.startswith("external/"):
            ws_root = "../" + ws_root[len("external/"):]
        if label_package:
            lib_root = ws_root + "/" + label_package
        else:
            lib_root = ws_root
    else:
        lib_root = label_package
    if lib_root.endswith("/lib") or lib_root == "lib":
        lib_root = lib_root[:-4] if lib_root.endswith("/lib") else ""
    return lib_root

def _dart_library_impl(ctx):
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    err = check_no_duplicate_srcs(ctx.label, ctx.files.srcs)
    if err != None:
        fail(err)

    # If this package mixes source-tree files with generated (bazel-out) files,
    # copy the sources into bin so the whole package shares one real directory —
    # then `part`/`import` resolve as filesystem siblings at compile and test
    # time, on all platforms. Generated files already in bin pass through.
    if is_mixed_package(ctx.files.srcs):
        own_srcs = copy_files_to_bin_actions(ctx, ctx.files.srcs)
    else:
        own_srcs = ctx.files.srcs

    # Collect transitive sources
    transitive_srcs = depset(
        direct = own_srcs,
        transitive = [dep[DartInfo].transitive_srcs for dep in ctx.attr.deps],
    )

    # Build a DartPackageInfo for this package
    this_pkg = DartPackageInfo(
        package_name = package_name,
        lib_root = lib_root,
        language_version = ctx.attr.language_version,
    )

    # Collect transitive packages
    transitive_packages = depset(
        direct = [this_pkg],
        transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps],
    )

    return [
        DefaultInfo(
            files = depset(own_srcs),
            runfiles = ctx.runfiles(files = own_srcs),
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
        "language_version": attr.string(
            doc = "Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Emitted as `languageVersion` in generated `package_config.json` entries. For pub packages this is set automatically by `pub.from_lock()`; for hand-written `dart_library` targets, set it from your workspace's `pubspec.yaml` if you want analyzer behaviour to match.",
        ),
    },
    toolchains = COPY_FILE_TO_BIN_TOOLCHAINS,
    doc = "Collects Dart sources and propagates dependency information via `DartInfo`. Does not compile.",
)
