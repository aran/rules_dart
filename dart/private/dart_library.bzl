"""Implementation of the dart_library rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:dart_info.bzl", "dart_info")

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

def check_srcs_under_lib_root(label, lib_root, srcs):
    """Detects `srcs` entries that do not sit under the package's `lib/`.

    A Dart package resolves `package:<name>/x.dart` to `<lib_root>/lib/x.dart`,
    and the consumer stages a package by stripping `lib_root` from each file
    (`colocate_packages`). A src outside `<lib_root>/lib/` therefore lands
    outside `lib/` in the staged tree and resolves to nothing. Nothing fails
    until the kernel compile, which reports only a missing path inside a
    `.pkgsrcs` directory — no target name, no mention of `lib/`.

    Generated sources are subject to the same rule: `declare_file` paths are
    relative to the *producing* rule's Bazel package, so a codegen target
    outside the Dart package root emits a path that no longer starts with
    `lib_root`.

    Args:
      label: The owning rule's label (included in the error message).
      lib_root: The package's library root, from `derive_lib_root`. Empty for a
        root package, where sources sit at `lib/` directly.
      srcs: The `srcs` list to inspect.

    Returns:
      An error message string for the first offending file, or `None`.
    """
    prefix = lib_root + "/lib/" if lib_root else "lib/"
    for src in srcs:
        if not src.short_path.startswith(prefix):
            return (
                ("%s: `%s` is not under `%s`, so it cannot be reached by a " +
                 "`package:` import — a Dart package's sources live in its " +
                 "`lib/` directory, and the compile stages them by stripping " +
                 "`%s`. Either move the file under `%s`, or, if it is " +
                 "generated, declare the producing codegen target in a BUILD " +
                 "file at the Dart package root so its output path resolves " +
                 "inside the package.") %
                (label, src.short_path, prefix, lib_root if lib_root else ".", prefix)
            )
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
        err = check_srcs_under_lib_root(ctx.label, lib_root, own_srcs)
        if err != None:
            fail(err)

    # `dart_library` is a pure collector: it propagates its sources (source-tree
    # and/or generated) and package metadata unchanged. Co-location of a
    # package's split-across-targets / source+generated files into one real
    # directory happens in the *consumer* (`dart_binary`/`dart_test`), which is
    # the only place that sees the package's complete file set.
    return [
        DefaultInfo(
            files = depset(own_srcs),
            runfiles = ctx.runfiles(files = own_srcs),
        ),
        dart_info(
            label = ctx.label,
            package_name = package_name,
            lib_root = lib_root,
            deps = ctx.attr.deps,
            srcs = own_srcs,
            code_assets = ctx.attr.code_assets,
            language_version = ctx.attr.language_version,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
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
        "code_assets": attr.label_list(
            doc = """Native code assets this package owns (see the `dart_code_asset` rule). \
Assets declared here propagate to every `dart_binary`/`dart_test` that depends on this library, \
directly or transitively — matching upstream, where depending on a package gets you its assets \
with no opt-in. Each `asset_id` must be namespaced to this library's `package_name`.""",
            providers = [DartCodeAssetInfo],
        ),
        "has_unreplaced_hook": attr.string(
            doc = """Path of a pub build hook (`hook/build.dart` / `hook/link.dart`) this \
package ships that rules_dart has no replacement for. Set by `pub.from_lock()`; hand-written \
`dart_library` targets leave it empty. A `dart_binary`/`dart_test` reaching such a package fails \
with an explanation, rather than producing a binary whose `@Native` bindings silently fail to \
resolve at runtime.""",
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
