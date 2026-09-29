"""The package an executable may state it belongs to, and the checks that keep it honest.

`dart_binary`, `dart_test`, `dart_js_binary` and `dart_wasm_binary` accept the
same package identity `dart_library` does — `package`, or inline
`package_name` / `language_version` — and none of it is required. Unset, an
executable contributes no package, exactly as before: its entrypoint takes
whatever version the package containing it gives it, or the SDK's own.

Set, the executable is a member of that package, rooted at its Bazel package
directory (`derive_lib_root`, as for `dart_library`). It then carries the
package's record like a library does, so the generated `package_config.json`
covers its entrypoint with that `languageVersion` at compile time, and analysis
and the `dart_analyze` aspect's format check read the same version for its
files.

A stated identity is a second statement of facts the build may already know —
which package a directory is, what version it has — so everything here is about
making the two agree or fail. `executable_package_error` holds the rules and is
pure, so each can be tested by calling it.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "PACKAGE_IDENTITY_ATTRS", "codegen_identity_error", "merge_package_records", "resolve_package_identity")
load("//dart/private:dart_info.bzl", "dart_analyzable_info", "dart_analyzable_info_with_package", "dart_info", "package_lib_prefix")
load("//dart/private:dart_library.bzl", "derive_lib_root", "derive_package_name")

# The identity attributes of every executable rule: `package` from
# `PACKAGE_IDENTITY_ATTRS`, and the inline pair it excludes.
EXECUTABLE_PACKAGE_ATTRS = PACKAGE_IDENTITY_ATTRS | {
    "package_name": attr.string(
        doc = "The Dart package this executable is part of. Optional: set it (or `language_version`, or `package`) only to make this target a member of a package rooted at its Bazel package directory, as a `dart_library` there would be; left unset, the target contributes no package and its entrypoint takes the version of the package whose root contains it. Defaults to the last component of the Bazel package path when only `language_version` is set. Must agree with every package in `deps` that shares its name or root. Set this or `package`, not both.",
    ),
    "language_version": attr.string(
        doc = "Dart language version of the package this executable is part of, in `<major>.<minor>` form. Emitted as the package's `languageVersion` in the generated `package_config.json`, so the entrypoint compiles, analyzes and is format-checked at it. For an executable whose Bazel package has no `dart_library` to state it. Must equal the version a `dart_library` of the same package states. Set this or `package`, not both.",
    ),
}

def _states_identity(ctx):
    return bool(ctx.attr.package or ctx.attr.package_name or ctx.attr.language_version)

def _in_root(path, root):
    """Whether a `short_path` lies under a package root directory."""
    if root == "":
        return not path.startswith("../")
    return path.startswith(root + "/")

def _how_stated(label, stated_by):
    return "%s (via %s)" % (label, stated_by)

def executable_package_error(label, own, stated_by, own_paths, dep_packages, reached_through):
    """Reports a stated executable package that contradicts what its deps say.

    The rules, each a pair of statements that can disagree:

      * **Its files are in its package.** Every own file must lie under the
        package root, and no package in `deps` may have a root nested deeper
        that also contains one of them — Dart gives a file to the innermost
        package containing it, so the stated version would not reach it.
      * **One name, one package.** If `deps` supply records named like this
        package, one of them must share its root. A name reached at several
        roots is legitimate (a split package; two pub hubs) and is not
        second-guessed — but a package whose every record is rooted elsewhere is
        a different package with the same name, and the build can keep only one.
      * **One root, one name.** Any package in `deps` rooted at the same
        directory must have the same name: one directory is one package.
      * **One package, one version.** A record in `deps` for the same package
        (same name and root) must state the same `language_version`, stated or
        not. The executable's record would otherwise decide the version of the
        library's files in this build only.

    A package in `deps` whose root merely *contains* this one, under a different
    name, is not a conflict: that is a nested package (a pub package's
    `example/`), and Dart gives the nested one's files its own version.

    Args:
      label: The executable's label.
      own: The executable's own `DartPackageInfo`.
      stated_by: How the identity was stated, for messages (e.g. "`package =
        //pkg:meta`").
      own_paths: `short_path`s of the executable's own sources.
      dep_packages: Every `DartPackageInfo` its `deps` reach, duplicates kept.
      reached_through: Function from a record to the label of the direct dep
        that supplies it, for messages.

    Returns:
      An error message, or `None`.
    """
    name = own.package_name
    root = own.lib_root
    shown_root = root or "."
    me = _how_stated(label, stated_by)

    for path in own_paths:
        if not _in_root(path, root):
            return (
                ("%s states package \"%s\", rooted at its Bazel package " +
                 "directory `%s`, but its source `%s` is outside that " +
                 "directory — Dart would not give it the package's language " +
                 "version. Move the file into this package, or drop `package` " +
                 "/ `package_name` / `language_version` so the file takes the " +
                 "version of the package that does contain it.") %
                (me, name, shown_root, path)
            )

    same_name = [p for p in dep_packages if p.package_name == name]
    if same_name and not [p for p in same_name if p.lib_root == root]:
        other = same_name[0]
        return (
            ("%s states package \"%s\" rooted at `%s`, but %s supplies package " +
             "\"%s\" rooted at `%s`. One package has one root, so these are two " +
             "packages with one name, and a build keeps only one of them. If " +
             "this target is part of that package, declare it in the BUILD " +
             "file at `%s`, or drop `package` / `package_name` / " +
             "`language_version` — its entrypoint then takes that package's " +
             "version if the package's root contains it. Otherwise give it a " +
             "different `package_name`.") %
            (me, name, shown_root, reached_through(other), name, other.lib_root or ".", other.lib_root or ".")
        )

    for p in dep_packages:
        if p.lib_root == root and p.package_name != name:
            return (
                ("%s states package \"%s\", but %s declares the same directory " +
                 "`%s` as package \"%s\". One directory is one package. Name " +
                 "the same package on both, ideally by pointing both at one " +
                 "`dart_package_metadata`.") %
                (me, name, reached_through(p), shown_root, p.package_name)
            )

    for p in dep_packages:
        if p.package_name != name or p.lib_root != root:
            continue
        theirs = getattr(p, "language_version", "")
        if theirs != own.language_version:
            return (
                ("%s states package \"%s\" at language version %s, but %s, " +
                 "the same package, states %s. One package has one language " +
                 "version, and this target's statement would decide it for " +
                 "the library's files in this build alone. Point both at one " +
                 "`dart_package_metadata`, or state the same " +
                 "`language_version` on each.") %
                (
                    me,
                    name,
                    own.language_version or "none",
                    reached_through(p),
                    theirs or "none",
                )
            )

    for path in own_paths:
        for p in dep_packages:
            r = p.lib_root
            if r != root and _in_root(r, root) and _in_root(path, r):
                return (
                    ("%s states package \"%s\" rooted at `%s`, but its source " +
                     "`%s` lies inside package \"%s\" (root `%s`, from %s), " +
                     "which Dart gives it instead. Declare this target in " +
                     "that package's BUILD file with its identity, or drop " +
                     "`package` / `package_name` / `language_version` here.") %
                    (me, name, shown_root, path, p.package_name, r, reached_through(p))
                )
    return None

def _reached_through(deps):
    def find(record):
        for dep in deps:
            if record in dep[DartInfo].transitive_packages.to_list():
                return str(dep.label)
        return "a dependency"

    return find

def executable_package(ctx, own_srcs):
    """Resolves an executable's package, checks it, and builds what it provides.

    Args:
      ctx: The executable rule's context, carrying `EXECUTABLE_PACKAGE_ATTRS`,
        `deps` and `srcs`.
      own_srcs: The rule's own source Files (`main` first, then `srcs`), before
        any colocation.

    Returns:
      `struct(record, packages, analyzable)`: the executable's own
      `DartPackageInfo` (`None` when it states none), the deduplicated package
      list to compile against with that record first, and its
      `DartAnalyzableInfo`.
    """
    dep_packages = depset(transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps]).to_list()
    if not _states_identity(ctx):
        return struct(
            record = None,
            packages = merge_package_records(dep_packages),
            analyzable = dart_analyzable_info(deps = ctx.attr.deps, srcs = own_srcs),
        )

    identity = resolve_package_identity(ctx)
    name = derive_package_name(identity.package_name, ctx.label.package, ctx.label.name)
    root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    if ctx.attr.package:
        stated_by = "`package = %s`" % ctx.attr.package.label
    elif identity.package_name:
        stated_by = "`package_name = \"%s\"`" % identity.package_name
    else:
        stated_by = "`language_version = \"%s\"`" % identity.language_version

    # Generated sources this target collects name the package they were
    # generated for; that is one more statement of the same identity.
    err = codegen_identity_error(
        ctx.label,
        ctx.attr.srcs,
        struct(package_name = name, language_version = identity.language_version),
    )
    if err != None:
        fail(err)

    # The package's `lib/` files are reachable as `package:` URIs and join the
    # package's sources; the rest (the entrypoint) belong to no `lib/`.
    prefix = package_lib_prefix(root)
    analyzable = dart_analyzable_info_with_package(
        label = ctx.label,
        package_name = name,
        lib_root = root,
        language_version = identity.language_version,
        deps = ctx.attr.deps,
        srcs = [f for f in own_srcs if not f.short_path.startswith(prefix)],
        package_srcs = [f for f in own_srcs if f.short_path.startswith(prefix)],
    )

    # The record alone, from the same constructor: `own_package_record` on the
    # closure would match a dependency's record for this same package first.
    record = dart_info(
        label = ctx.label,
        package_name = name,
        lib_root = root,
        language_version = identity.language_version,
    ).transitive_packages.to_list()[0]

    err = executable_package_error(
        ctx.label,
        record,
        stated_by,
        [f.short_path for f in own_srcs],
        dep_packages,
        _reached_through(ctx.attr.deps),
    )
    if err != None:
        fail(err)

    return struct(
        record = record,
        packages = merge_package_records([record] + dep_packages),
        analyzable = analyzable,
    )
