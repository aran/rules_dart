"""Implementation of the dart_library rule."""

load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")

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

    if ctx.attr.srcs_dir:
        # Sources arrive pre-assembled as one directory (a `dart_source_set`);
        # the directory itself is the package root.
        if ctx.files.srcs:
            fail("%s: set either `srcs` or `srcs_dir`, not both." % ctx.label)
        own_srcs = ctx.files.srcs_dir
        lib_root = own_srcs[0].short_path
    else:
        # `srcs` may be empty: a `dart_library` with only `deps` is a valid
        # aggregate façade that re-exports its dependencies.
        err = check_no_duplicate_srcs(ctx.label, ctx.files.srcs)
        if err != None:
            fail(err)
        own_srcs = ctx.files.srcs
        lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # `dart_library` is a pure collector: it propagates its sources (source-tree
    # and/or generated) and package metadata unchanged. Co-location of a
    # package's split-across-targets / source+generated files into one real
    # directory happens in the *consumer* (`dart_binary`/`dart_test`), which is
    # the only place that sees the package's complete file set.
    transitive_srcs = depset(
        direct = own_srcs,
        transitive = [dep[DartInfo].transitive_srcs for dep in ctx.attr.deps],
    )
    this_pkg = DartPackageInfo(
        package_name = package_name,
        lib_root = lib_root,
        language_version = ctx.attr.language_version,
    )
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
            doc = "Dart source files (`.dart`), source-tree or generated. Typically `glob([\"lib/**/*.dart\"])`, optionally plus `dart_codegen` outputs. Generated members are co-located with the rest of the package by the consuming `dart_binary`/`dart_test`. Mutually exclusive with `srcs_dir`.",
            allow_files = [".dart"],
        ),
        "srcs_dir": attr.label(
            doc = "A pre-assembled source directory (a `dart_source_set`) to use as this library's package root, instead of `srcs`. For reuse/composition; usually you just list files in `srcs`.",
            allow_files = True,
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
    doc = "Collects Dart sources and propagates dependency information via `DartInfo`. Does not compile or assemble; consumers co-locate generated sources.",
)
