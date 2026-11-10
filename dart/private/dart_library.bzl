"""Implementation of the dart_library rule."""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "PACKAGE_IDENTITY_ATTRS", "codegen_identity_error", "own_packages", "resolve_package_identity")
load("//dart/private:dart_import_check.bzl", "LIBRARY_IMPORT_CHECKER_ATTRS", "library_import_check")
load("//dart/private:dart_info.bzl", "dart_info", "dart_package_info", "package_info_from_metadata", "package_lib_prefix")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:runtime.bzl", "RUNTIME_INDEPENDENT_ATTR", "runtime_reset_when_independent")

def check_no_duplicate_srcs(label, srcs, attr_name = "srcs"):
    """Detects two entries that resolve to the same package-relative path.

    Typically fires when a stale `build_runner`-generated file is listed in
    the source tree alongside a codegen target producing the same output.

    Args:
      label: The owning rule's label (included in the error message).
      srcs: The files to inspect.
      attr_name: The attribute the files came from, named in the message so a
        collision between two `resources` does not send the reader searching
        `srcs`. A caller passing srcs and resources together keeps the default:
        a src-vs-resource collision is unreachable, because identical short
        paths imply identical extensions and a `.dart` file in `resources` is
        refused before this runs — so a mixed list can only collide inside
        `srcs`.

    Returns:
      An error message string if a collision is found, or `None` otherwise.
    """
    seen = {}
    for src in srcs:
        prev = seen.get(src.short_path)
        if prev != None and prev != src.path:
            return (
                ("%s: `%s` contains two files that resolve to the same " +
                 "package-relative path `%s` — typically a stale " +
                 "`build_runner`-generated file in the source tree listed " +
                 "alongside a codegen target producing the same output. " +
                 "First: %s. Second: %s.") % (label, attr_name, src.short_path, prev, src.path)
            )
        seen[src.short_path] = src.path
    return None

def check_files_under_package_root(label, package_root, files, attr_name = "srcs"):
    """Detects `srcs`/`resources` entries that do not sit under the package's `lib/`.

    A Dart package resolves `package:<name>/x.dart` to `<package_root>/lib/x.dart`,
    and the consumer stages a package by stripping `package_root` from each file
    (`colocate_packages`). A file outside `<package_root>/lib/` therefore lands
    outside `lib/` in the staged tree and resolves to nothing. Nothing fails
    until the kernel compile, which reports only a missing path inside a
    `.pkgsrcs` directory — no target name, no mention of `lib/`.

    Generated files are subject to the same rule: `declare_file` paths are
    relative to the *producing* rule's Bazel package, so a codegen target
    outside the Dart package root emits a path that no longer starts with
    `package_root`.

    Args:
      label: The owning rule's label (included in the error message).
      package_root: The package's library root, from `derive_package_root`. Empty for a
        root package, where files sit at `lib/` directly.
      files: The file list to inspect.
      attr_name: Attribute the list came from, named in the error message.

    Returns:
      An error message string for the first offending file, or `None`.
    """
    prefix = package_lib_prefix(package_root)
    for f in files:
        if not f.short_path.startswith(prefix):
            return (
                ("%s: `%s` in `%s` is not under `%s`, so it cannot be reached " +
                 "by a `package:` URI — a Dart package's files live in its " +
                 "`lib/` directory, and staging strips `%s`. Either move the " +
                 "file under `%s`, or, if it is generated, declare the " +
                 "producing codegen target in a BUILD file at the Dart " +
                 "package root so its output path resolves inside the " +
                 "package.") %
                (label, f.short_path, attr_name, prefix, package_root if package_root else ".", prefix)
            )
    return None

def locate_package_root(workspace_root, label_package, files = []):
    """The package root of a target, from the directory of its BUILD file.

    A BUILD file at a package's root takes its own directory. A BUILD file
    anywhere inside the package's `lib/` — `lib/` itself or a directory under
    it, `lib/src/model/` — belongs to the directory above that `lib`, as Dart
    reads `<root>/lib/src/model/a.dart` as `package:<name>/src/model/a.dart`.
    The root is the same for every target of one package, wherever in it the
    target's BUILD file sits.

    A directory named `lib` inside another `lib/` makes that ambiguous: a
    BUILD file at `x/lib/y/` holding `x/lib/y/lib/a.dart` may be the root of a
    package `y` or a directory of the package at `x`. Either case is an error,
    not a guess.

    For external repos, converts "external/X" to "../X" to match
    File.short_path convention. Only the label's package path is read for
    `lib` components, never the repository's directory name.

    Args:
        workspace_root: The workspace root of the label (ctx.label.workspace_root).
        label_package: The Bazel label package path (ctx.label.package).
        files: The target's own files, which tell a package whose root is
          itself inside a `lib` directory (they sit under its own `lib/`).

    Returns:
        `struct(root, error)`: the root's short_path ("" for the main
        repository's root), and an error message or None.
    """
    ws_root = workspace_root
    if ws_root.startswith("external/"):
        ws_root = "../" + ws_root[len("external/"):]

    def under_ws(rel):
        if ws_root and rel:
            return ws_root + "/" + rel
        return ws_root or rel

    parts = label_package.split("/") if label_package else []
    lib_at = [i for i, part in enumerate(parts) if part == "lib"]
    if len(lib_at) > 1:
        return struct(root = None, error = (
            ("`//%s` has a directory named `lib` inside another `lib/`, so its " +
             "Dart package root is ambiguous: it is the directory above one of " +
             "the `lib` components, and nothing says which. Rename the inner " +
             "`lib` directory.") % label_package
        ))
    if lib_at:
        own_lib = under_ws(label_package) + "/lib/"
        for f in files:
            if f.short_path.startswith(own_lib):
                return struct(root = None, error = (
                    ("`%s` sits in a directory named `lib` under `//%s`, which is " +
                     "itself inside a `lib/`, so its Dart package root is " +
                     "ambiguous: `//%s` or `//%s`. Rename the inner `lib` " +
                     "directory, or move the package out of the outer one.") %
                    (f.short_path, label_package, label_package, "/".join(parts[:lib_at[0]]))
                ))
        parts = parts[:lib_at[0]]
    return struct(root = under_ws("/".join(parts)), error = None)

def derive_package_root(workspace_root, label_package):
    """The package root of a target, from its label alone (see `locate_package_root`).

    Fails where the path is ambiguous. Rules that have the target's files
    call `locate_package_root` with them, which also catches a package rooted inside
    a `lib` directory.

    Args:
        workspace_root: The workspace root of the label (ctx.label.workspace_root).
        label_package: The Bazel label package path (ctx.label.package).

    Returns:
        The package root's short_path, without the `lib/` component.
    """
    result = locate_package_root(workspace_root, label_package)
    if result.error != None:
        fail(result.error)
    return result.root

def _dart_library_impl(ctx):
    identity = resolve_package_identity(ctx)

    # The one point a generated source and the library collecting it meet.
    err = codegen_identity_error(ctx.label, ctx.attr.srcs, identity.package_name, identity.metadata)
    if err != None:
        fail(err)

    own_resources = ctx.files.resources
    for f in own_resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the files the compiler never reads; a `.dart` file listed " +
                 "there would be staged for the analyzer and withheld from " +
                 "the compile. Move it to `srcs`.") % (ctx.label, f.short_path),
            )

    if ctx.attr.srcs_dir:
        # Sources arrive pre-assembled as one directory (a `dart_source_set`);
        # the directory itself is the package root.
        if ctx.files.srcs:
            fail("%s: set either `srcs` or `srcs_dir`, not both." % ctx.label)
        if own_resources:
            fail(
                ("%s: set either `resources` or `srcs_dir`, not both. A " +
                 "pre-assembled directory is opaque — it already carries " +
                 "every file of the package, non-Dart ones included.") % ctx.label,
            )
        own_srcs = ctx.files.srcs_dir
        package_root = own_srcs[0].short_path
    else:
        # `srcs` may be empty: a `dart_library` with only `deps` is a valid
        # aggregate façade that re-exports its dependencies.
        # Checked per attribute rather than over the concatenation, so the
        # message names the list the reader has to go and look at. The two
        # cannot collide with each other — identical short paths imply
        # identical extensions, and a `.dart` file in `resources` is refused
        # above — so nothing is lost by checking them apart.
        err = check_no_duplicate_srcs(ctx.label, ctx.files.srcs)
        if err == None:
            err = check_no_duplicate_srcs(ctx.label, own_resources, "resources")
        if err != None:
            fail(err)
        own_srcs = ctx.files.srcs
        if identity.metadata != None:
            # The declaration's directory is the package root, as a pubspec's is.
            package_root = identity.metadata.package_root
        else:
            root = locate_package_root(ctx.label.workspace_root, ctx.label.package, own_srcs + own_resources)
            if root.error != None:
                fail("%s: %s" % (ctx.label, root.error))
            package_root = root.root
        err = check_files_under_package_root(ctx.label, package_root, own_srcs)
        if err != None:
            fail(err)
        err = check_files_under_package_root(ctx.label, package_root, own_resources, "resources")
        if err != None:
            fail(err)

    if identity.metadata != None:
        record = package_info_from_metadata(ctx.label, identity.metadata, package_root)
    else:
        record = dart_package_info(
            label = ctx.label,
            package_name = identity.package_name,
            package_root = package_root,
            language_version = "",
        )

    # `dart_library` is a pure collector: it propagates its sources (source-tree
    # and/or generated) and package metadata unchanged. Co-location of a
    # package's split-across-targets / source+generated files into one real
    # directory happens in the *consumer* (`dart_binary`/`dart_test`), which is
    # the only place that sees the package's complete file set. Its one
    # action is the check of what its sources import, a validation.
    info = dart_info(
        label = ctx.label,
        packages = [record],
        deps = ctx.attr.deps,
        srcs = own_srcs,
        resources = own_resources,
    )
    return [
        DefaultInfo(
            files = depset(own_srcs + own_resources),
            runfiles = ctx.runfiles(files = own_srcs + own_resources),
        ),
        info,
        # What `bazel coverage` reports on for a test that reaches this.
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
            extensions = ["dart"],
        ),
    ] + library_import_check(ctx, own_packages(info))

dart_library = rule(
    implementation = _dart_library_impl,
    cfg = runtime_reset_when_independent,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files (`.dart`), source-tree or generated. Typically `glob([\"lib/**/*.dart\"])`, optionally plus `dart_codegen` outputs. Generated members are co-located with the rest of the package by the consuming `dart_binary`/`dart_test`. Mutually exclusive with `srcs_dir`.",
            allow_files = [".dart"],
        ),
        "resources": attr.label_list(
            doc = """Non-Dart files this package ships inside `lib/` — part of its published \
surface, but never compiled. `package:sky_engine`'s `lib/_embedder.yaml`, which the analyzer \
reads to resolve `dart:ui`, and `package:dwds`'s `lib/src/injected/client.js`, which it serves \
to the browser, are both this. Anything under `lib/` is addressable as `package:<name>/<path>` \
whatever its extension, so these are members of the package, not a consumer's `data`. \
They are staged wherever the package itself is staged — the analyzer's hermetic project tree — \
and ride the runfiles of every `dart_binary`/`dart_test` that depends on this library, mirroring \
pub, where the package directory exists whole on disk at run time. They are never compile inputs. \
`.dart` files belong in `srcs`; files outside `lib/` have no `package:` URI and belong in a \
consumer's `data`.""",
            allow_files = True,
        ),
        "srcs_dir": attr.label(
            doc = "A pre-assembled source directory (a `dart_source_set`) to use as this library's package root, instead of `srcs`. The directory is opaque and carries the package's non-Dart files too, so `resources` is rejected alongside it. For reuse/composition; usually you just list files in `srcs`.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "Other `dart_library` targets this library depends on. Their sources and package metadata are propagated transitively.",
            providers = [DartInfo],
        ),
    } | PACKAGE_IDENTITY_ATTRS | RUNTIME_INDEPENDENT_ATTR | LIBRARY_IMPORT_CHECKER_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Collects Dart sources and propagates dependency information via `DartInfo`. Its package is the one the `dart_package_metadata` it names in `package` declares, or, naming none, one named after its root directory that states nothing else. Does not compile or assemble; consumers co-locate generated sources. Its `_validation` output group checks what its sources import, export and include as parts against its `deps` (see `dart_import_check.bzl`), so any build of the library runs the check.",
)
