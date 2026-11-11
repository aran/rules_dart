"""The package an executable may name, and the checks that keep it honest.

`dart_binary`, `dart_test`, `dart_js_binary` and `dart_wasm_binary` accept the
`package` every target of a Dart package takes, and none requires it. Unset, an
executable contributes no package: its entrypoint takes whatever version the
package containing it gives it through its `deps`, or the SDK's own.

Set, the executable is a member of the package its `dart_package_metadata`
declares, rooted at the declaration's package root wherever the executable's own
BUILD file is, as Dart gives every file under a pubspec's directory to that
package. It then carries the package's record like a library does, so the
generated `package_config.json` covers its entrypoint with that
`languageVersion` at compile time, and analysis and the `dart_analyze`
aspect's format check read the same version for its files.

`executable_package_error` holds the rules that keep the executable's files and
the packages in its `deps` consistent with that, and is pure, so each can be
tested by calling it.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "codegen_identity_error", "executable_package_record", "package_identity_attrs", "program_packages", "resolve_package_identity")
load("//dart/private:dart_info.bzl", "dart_analyzable_info", "dart_analyzable_info_no_package", "package_lib_prefix")

visibility("//dart/...")

# The package attribute of every executable rule.
EXECUTABLE_PACKAGE_ATTRS = package_identity_attrs(
    doc = "The `dart_package_metadata` declaring the Dart package this executable is a member of, wherever its BUILD file is: its own files take that package's language version, and its record joins the packages it compiles against. Unset, the executable contributes no package, and its entrypoint takes the version of a package its `deps` bring whose root contains it, or the SDK's own.",
)

def _in_root(path, root):
    """Whether a `short_path` lies under a package root directory."""
    if root == "":
        return not path.startswith("../")
    return path.startswith(root + "/")

def executable_package_error(label, own, own_paths, dep_packages, reached_through):
    """Reports an executable's package that contradicts its files or its deps.

    The rules:

      * **Its files are in its package.** Every own file must lie under the
        package root, and no package in `deps` may have a root nested deeper
        that also contains one of them — Dart gives a file to the innermost
        package containing it, so the package's version would not reach it.
      * **One name, one package.** If `deps` supply records named like this
        package, one of them must share its root. A name reached at several
        roots is legitimate (two pub hubs) and is not second-guessed — but a
        package whose every record is rooted elsewhere is a different package
        with the same name, and the build can keep only one.
      * **One root, one name.** Any package in `deps` rooted at the same
        directory must have the same name: one directory is one package.

    That a record in `deps` for the same package names the same
    `dart_package_metadata` is `merge_package_records`'s check, as for any two
    records of one package.

    A package in `deps` whose root merely *contains* this one, under a different
    name, is not a conflict: that is a nested package (a pub package's
    `example/`), and Dart gives the nested one's files its own version.

    Args:
      label: The executable's label.
      own: The executable's own `DartPackageInfo`, from the declaration it
        names.
      own_paths: `short_path`s of the executable's own sources.
      dep_packages: Every `DartPackageInfo` its `deps` reach, duplicates kept.
      reached_through: Function from a record to the label of the direct dep
        that supplies it, for messages.

    Returns:
      An error message, or `None`.
    """
    name = own.package_name
    root = own.package_root
    shown_root = root or "."
    me = "%s (via `package = %s`)" % (label, own.metadata)

    for path in own_paths:
        if not _in_root(path, root):
            return (
                ("%s is part of package \"%s\", rooted at `%s`, but its " +
                 "source `%s` is outside that directory — Dart would not give " +
                 "it the package's language version. Move the file into the " +
                 "package, or drop `package` so the file takes the version of " +
                 "the package that does contain it.") %
                (me, name, shown_root, path)
            )

    same_name = [p for p in dep_packages if p.package_name == name]
    if same_name and not [p for p in same_name if p.package_root == root]:
        other = same_name[0]
        return (
            ("%s is part of package \"%s\" rooted at `%s`, but %s supplies " +
             "package \"%s\" rooted at `%s`. One package has one root, so " +
             "these are two packages with one name, and a build keeps only " +
             "one of them. If this target is part of that package, name its " +
             "`dart_package_metadata`; otherwise give one of the two packages " +
             "a different `package_name`.") %
            (me, name, shown_root, reached_through(other), name, other.package_root or ".")
        )

    for p in dep_packages:
        if p.package_root == root and p.package_name != name:
            return (
                ("%s is part of package \"%s\", but %s declares the same " +
                 "directory `%s` as package \"%s\". One directory is one " +
                 "package: point both at one `dart_package_metadata`.") %
                (me, name, reached_through(p), shown_root, p.package_name)
            )

    for path in own_paths:
        for p in dep_packages:
            r = p.package_root
            if r != root and _in_root(r, root) and _in_root(path, r):
                return (
                    ("%s is part of package \"%s\" rooted at `%s`, but its " +
                     "source `%s` lies inside package \"%s\" (root `%s`, " +
                     "from %s), which Dart gives it instead. Name that " +
                     "package's `dart_package_metadata`, or drop `package` " +
                     "here.") %
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
      `struct(record, package_files, packages, analyzable)`: the
      executable's own `DartPackageInfo` (`None` when it names no package),
      its own files under that package's `lib/`, the program's
      packages (`program_packages`) to compile against, and its
      `DartAnalyzableInfo`.
    """
    dep_packages = depset(transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps]).to_list()
    identity = resolve_package_identity(ctx)
    if identity.metadata == None:
        return struct(
            record = None,
            package_files = [],
            packages = program_packages(None, ctx.attr.deps),
            analyzable = dart_analyzable_info_no_package(deps = ctx.attr.deps, entry_srcs = own_srcs),
        )

    # Generated sources this target collects name the package they were
    # generated for, and must be this one's.
    err = codegen_identity_error(ctx.label, ctx.attr.srcs, identity.package_name, identity.metadata)
    if err != None:
        fail(err)

    # The declaration's package root is this target's, wherever this target's
    # BUILD file is.
    root = identity.package_root

    # The package's `lib/` files are reachable as `package:` URIs and join the
    # package's sources; the rest (the entrypoint) belong to no `lib/`.
    prefix = package_lib_prefix(root)
    analyzable = dart_analyzable_info(
        label = ctx.label,
        packages = [executable_package_record(ctx.label, identity)],
        deps = ctx.attr.deps,
        srcs = [f for f in own_srcs if f.short_path.startswith(prefix)],
        entry_srcs = [f for f in own_srcs if not f.short_path.startswith(prefix)],
    )

    # The record alone, not looked up in the closure, which may hold a
    # dependency's record for this same package.
    record = analyzable.dart_info.packages[0]

    err = executable_package_error(
        ctx.label,
        record,
        [f.short_path for f in own_srcs],
        dep_packages,
        _reached_through(ctx.attr.deps),
    )
    if err != None:
        fail(err)

    return struct(
        record = record,
        package_files = [f for f in own_srcs if f.short_path.startswith(prefix)],
        packages = program_packages(record, ctx.attr.deps),
        analyzable = analyzable,
    )
