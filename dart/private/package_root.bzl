"""Where a Dart package is rooted, from the BUILD file of a target of it."""

visibility("//dart/...")

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
