"""Implementation of the dart_library rule."""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "codegen_identity_error", "identity_package_record", "own_packages", "package_identity_attrs", "resolve_package_identity")
load("//dart/private:dart_import_check.bzl", "LIBRARY_IMPORT_CHECKER_ATTRS", "library_import_check")
load("//dart/private:dart_info.bzl", "package_info_from_metadata", "package_lib_prefix")
load("//dart/private:dart_summary.bzl", "SUMMARY_ATTRS", "dart_info")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:package_root.bzl", "locate_package_root")
load("//dart/private:runtime.bzl", "RUNTIME_INDEPENDENT_ATTR", "runtime_reset_when_independent")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

visibility("//dart/...")

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
    whether its files are read in place or staged by stripping `package_root`
    (`colocate_packages`). A file outside `<package_root>/lib/` therefore
    resolves to nothing. Nothing fails
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

def checked_package_info(label, metadata, srcs, resources = []):
    """The `DartPackageInfo` of a package declared by a `dart_package_metadata`, once its files are checked.

    The package root is the declaration's, as a pubspec's directory is. Fails
    when two files resolve to the same path or one is not under the package's
    `lib/`.

    Args:
      label: The target's label.
      metadata: The `DartPackageMetadataInfo` the target names.
      srcs: The package's `lib/**/*.dart` Files.
      resources: The rest of its `lib/` Files.

    Returns:
      A `DartPackageInfo`.
    """
    package_root = metadata.package_root
    for err in [
        check_no_duplicate_srcs(label, srcs),
        check_no_duplicate_srcs(label, resources, "resources"),
        check_files_under_package_root(label, package_root, srcs),
        check_files_under_package_root(label, package_root, resources, "resources"),
    ]:
        if err != None:
            fail(err)
    return package_info_from_metadata(label, metadata, package_root)

def library_package(ctx, srcs, resources = [], assembled_root = None):
    """The Dart package a library target is, from the `dart_package_metadata` it names.

    What `dart_library` does with `package`, for a rule set whose library rule
    declares it (`package_identity_attrs()`): resolves the declaration, checks
    that the target's files sit under the package's `lib/` and collide with
    none, and builds the record. A library naming a declaration in another
    directory fails here, naming the file. A target naming none is named after
    its root's directory, which `locate_package_root` finds from the BUILD
    file and the files, and states nothing else.

    A generated source among the target's `srcs` (`ctx.attr.srcs`, the targets)
    must be of the package the target names: a codegen rule naming another
    declaration fails, naming both.

    Args:
      ctx: The rule context. Must declare `package` (`package_identity_attrs()`)
        and `srcs`.
      srcs: The target's own Dart Files.
      resources: The target's other files under `lib/`.
      assembled_root: The `short_path` of the directory a pre-assembled
        package is (a `copy_to_directory`), when the target's sources are that
        and not files to check; they are then not looked at.

    Returns:
      `struct(record, metadata, package_name, package_root, language_version)`:
      the target's `DartPackageInfo` and what it came from, as
      `resolve_package_identity` returns it, with the root.
    """
    identity = resolve_package_identity(ctx)

    # The one point a generated source and the library collecting it meet.
    err = codegen_identity_error(ctx.label, ctx.attr.srcs, identity.package_name, identity.metadata)
    if err != None:
        fail(err)
    if assembled_root != None:
        record = identity_package_record(ctx.label, identity, assembled_root)
    elif identity.metadata != None:
        record = checked_package_info(ctx.label, identity.metadata, srcs, resources)
    else:
        # Checked per attribute rather than over the concatenation, so the
        # message names the list the reader has to go and look at. The two
        # cannot collide with each other: identical short paths imply
        # identical extensions, and a `.dart` file in `resources` is refused
        # by the rule before this runs.
        for err in [
            check_no_duplicate_srcs(ctx.label, srcs),
            check_no_duplicate_srcs(ctx.label, resources, "resources"),
        ]:
            if err != None:
                fail(err)
        root = locate_package_root(ctx.label.workspace_root, ctx.label.package, srcs + resources)
        if root.error != None:
            fail("%s: %s" % (ctx.label, root.error))
        for err in [
            check_files_under_package_root(ctx.label, root.root, srcs),
            check_files_under_package_root(ctx.label, root.root, resources, "resources"),
        ]:
            if err != None:
                fail(err)
        record = identity_package_record(ctx.label, identity, root.root)
    return struct(
        record = record,
        metadata = identity.metadata,
        package_name = identity.package_name,
        package_root = record.package_root,
        language_version = identity.language_version,
    )

def library_sources(ctx):
    """A library target's own files and the package they are, checked.

    For a rule with `LIBRARY_SOURCE_ATTRS` and `package_identity_attrs()`:
    `dart_library`, and each member of a `dart_package_cycle`.

    Args:
      ctx: The rule context.

    Returns:
      `struct(srcs, resources, package)`: the Dart Files (or the one source
      directory), the other files under `lib/`, and `library_package()`'s
      result.
    """
    resources = ctx.files.resources
    for f in resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the files the compiler never reads; a `.dart` file listed " +
                 "there would be staged for the analyzer and withheld from " +
                 "the compile. Move it to `srcs`.") % (ctx.label, f.short_path),
            )

    if ctx.attr.srcs_dir:
        # Sources arrive pre-assembled as one directory (a `copy_to_directory`);
        # the directory itself is the package root.
        if ctx.files.srcs:
            fail("%s: set either `srcs` or `srcs_dir`, not both." % ctx.label)
        if resources:
            fail(
                ("%s: set either `resources` or `srcs_dir`, not both. A " +
                 "pre-assembled directory is opaque — it already carries " +
                 "every file of the package, non-Dart ones included.") % ctx.label,
            )
        srcs = ctx.files.srcs_dir
        package = library_package(ctx, srcs, assembled_root = srcs[0].short_path)
    else:
        # `srcs` may be empty: a `dart_library` with only `deps` is a valid
        # aggregate façade that re-exports its dependencies.
        srcs = ctx.files.srcs
        package = library_package(ctx, srcs, resources)

    return struct(srcs = srcs, resources = resources, package = package)

# The files of a library target: `dart_library`'s, and each
# `dart_package_member`'s.
LIBRARY_SOURCE_ATTRS = {
    "srcs": attr.label_list(
        doc = "Dart source files (`.dart`), source-tree or generated. Typically `glob([\"lib/**/*.dart\"])`, optionally plus `dart_codegen` outputs. Generated members join the hand-written ones wherever a consumer reads the package: the VM compiles read both in place, through roots spanning the source tree and `bazel-out`, and the web compilers and the analyzer stage them into one project. Mutually exclusive with `srcs_dir`.",
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
        doc = "A pre-assembled source directory (a bazel_lib `copy_to_directory`) to use as this library's package root, instead of `srcs`. The directory is opaque and carries the package's non-Dart files too, so `resources` is rejected alongside it. For reuse/composition; usually you just list files in `srcs`.",
        allow_files = True,
    ),
}

def _dart_library_impl(ctx):
    sources = library_sources(ctx)
    own_srcs = sources.srcs
    own_resources = sources.resources
    package = sources.package

    # `dart_library` is a pure collector: it propagates its sources (source-tree
    # and/or generated) and package metadata unchanged. Co-location of a
    # package's split-across-targets / source+generated files into one real
    # directory happens in the *consumer* (`dart_binary`/`dart_test`), which is
    # the only place that sees the package's complete file set. Its one
    # action is the check of what its sources import, a validation.
    info = dart_info(
        ctx = ctx,
        packages = [package.record],
        deps = ctx.attr.deps,
        srcs = own_srcs,
        resources = own_resources,
        data = ctx.attr.data,
    )
    runfiles = ctx.runfiles(files = own_srcs + own_resources)
    return [
        DefaultInfo(
            files = depset(own_srcs + own_resources),
            runfiles = runfiles.merge(info.runfiles) if info.runfiles != None else runfiles,
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
    attrs = LIBRARY_SOURCE_ATTRS | {
        "deps": attr.label_list(
            doc = "Other `dart_library` targets this library depends on. Their sources and package metadata are propagated transitively.",
            providers = [DartInfo],
        ),
        "data": attr.label_list(
            doc = """Files the library needs at run time, outside its package's `lib/`: a \
fixture, a model, a tool it runs. They are never compile inputs. With their own runfiles, they \
join the runfiles of every `dart_binary`/`dart_test` that depends on this library, directly or \
not, as `py_library`'s and `go_library`'s `data` do, and are found there with `rlocation`. \
Files under `lib/` are the package's own and belong in `resources`.""",
            allow_files = True,
        ),
    } | package_identity_attrs() | RUNTIME_INDEPENDENT_ATTR | LIBRARY_IMPORT_CHECKER_ATTRS | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Collects Dart sources and propagates dependency information via `DartInfo`. Its package is the one the `dart_package_metadata` it names in `package` declares, or, naming none, one named after its root directory that states nothing else. Does not compile or assemble; each consumer reads its sources, generated ones included, as `srcs` describes. Its `_validation` output group checks what its sources import, export and include as parts against its `deps` (see `dart_import_check.bzl`), so any build of the library runs the check.",
)
