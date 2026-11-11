"""Serves a `source: path` pub package from its directory, for a repository.

`pub.from_lock(build_from_pubspec = [...])`'s `pub_lock_path_package` and
rules_flutter's `flutter_pub_package` call `fetch_pub_path`, so one local
package is the same tree whichever rule builds it.

The repository links the entries its caller names, each at its own path, and
nothing else: a directory pub, an IDE or Gradle writes into (`.dart_tool/`,
`build/`, `android/.gradle`) is never linked or watched, so writing there
neither refetches the package nor reaches its build. An entry may be nested
(`android/src`): its parent is then a real directory of the repository, which
the caller can write its own files into without writing through a link into
the package. Each linked entry is watched, so adding, removing or changing a
file under it refetches the repository, and so is each entry that is missing,
so creating one refetches it too.

A package with a Bazel build of its own is mapped with `resolve` instead:
linking a `BUILD` file in would make the directory holding it a package of the
repository, which the generated build's globs then silently skip. So any
Bazel file under a linked entry fails the fetch.

The repository depends on files outside Bazel's control, so a rule calling
this must not mark itself reproducible.
"""

visibility("//dart/...")

# The files that would make a directory of the repository a Bazel package or
# a repository boundary.
_BAZEL_FILES = ["BUILD", "BUILD.bazel", "MODULE.bazel", "REPO.bazel", "WORKSPACE", "WORKSPACE.bazel", "WORKSPACE.bzlmod"]

def _check_entry(entry):
    parts = entry.split("/")
    if entry.startswith("/") or "\\" in entry or [p for p in parts if p in ("", ".", "..")]:
        fail("fetch_pub_path: `%s` is not a relative path inside the package: name each entry by its path below the package directory, with `/` between its parts." % entry)
    return parts

def _child(directory, parts):
    # The entry at exactly these names: on a case-insensitive disk `exists`
    # would also find `license` for `LICENSE`, which pub would not.
    path = directory
    for part in parts:
        # Unwatched: each entry is watched on its own, missing ones too, and
        # watching this listing would refetch on tool output beside them.
        if not path.is_dir or part not in [c.basename for c in path.readdir(watch = "no")]:
            return None
        path = path.get_child(part)
    return path

def _bazel_files(path, entry):
    found = []
    pending = [(path, entry)]
    for _ in range(1000000):
        if not pending:
            break
        current, name = pending.pop()
        if current.is_dir:
            # `watch_tree` on the entry covers these.
            pending.extend([(c, name + "/" + c.basename) for c in current.readdir(watch = "no")])
        elif current.basename in _BAZEL_FILES:
            found.append(name)
    return sorted(found)

def fetch_pub_path(rctx, directory, entries):
    """Links the named entries of a local package directory into the repository.

    Args:
      rctx: The repository context.
      directory: The package directory, a `path`. Pub's lock records it
        relative to the lock: resolve it against `rctx.path(<lock label>).dirname`,
        so no attribute of the repository, which the lock file records, holds
        where the checkout is.
      entries: Paths below `directory` to serve, such as `pubspec.yaml`, `lib`
        or `android/src`. Each is linked at its own path, a missing one is
        skipped, and every one is watched.
    """
    root = rctx.path(directory)
    rctx.watch(root)
    if not root.exists:
        fail(("fetch_pub_path: the package directory %s does not exist. The lock lists the " +
              "package by path; check out that directory, or name the package in `resolve` " +
              "or `ignored` instead.") % root)
    if not root.is_dir:
        fail("fetch_pub_path: %s is not a directory." % root)
    found = []
    for entry in entries:
        parts = _check_entry(entry)
        src = _child(root, parts)
        if src == None:
            rctx.watch(root.get_child(*parts))
            continue
        if src.is_dir:
            found.extend(_bazel_files(src, entry))
            rctx.watch_tree(src)
        else:
            if src.basename in _BAZEL_FILES:
                found.append(entry)
            rctx.watch(src)
        rctx.symlink(src, entry)
    if found:
        fail(("fetch_pub_path: %s has a Bazel build of its own (%s). Map the package to the " +
              "target that builds it, with `resolve`, instead of building it from its " +
              "pubspec.") % (root, ", ".join(found)))
