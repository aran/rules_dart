"""Serves a `source: path` pub package from its directory, for a repository.

`pub.from_lock(build_from_pubspec = [...])`'s `pub_lock_path_package` and
rules_flutter's `flutter_pub_package` call `link_pub_path`, so one local
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
Bazel file under a linked entry is a refusal, as is a directory that is not
there. A refusal is returned, not raised: `bazel fetch --all` and `bazel vendor`
fetch packages no build uses, so only the builds using this one should fail.

The repository depends on files outside Bazel's control, this machine's, so a
rule calling this is `local = True`, as Bazel's `local_repository` is: never
reproducible, and left out by `bazel vendor` rather than fixed to one content.
That holds inside the lock's repository too, whose files the checkout already
has, and for a directory outside it (`pub_path_is_outside`), which only this
machine has.

A lock's `path` means what pub takes it to mean: an absolute path as it is, and
a relative one against the lock's directory, with its `..`s collapsed before any
symbolic link is followed. Two paths name one package when they reach one
directory once links are resolved, the comparison pub makes
(`pub_lock_path_location`).
"""

load("//dart/pub/private:build_content.bzl", "lock_path_in_repo", "normalize_pub_path", "pub_directory_source", "pub_path_root", "pub_path_source")

visibility("//dart/...")

# The files that would make a directory of the repository a Bazel package or
# a repository boundary.
_BAZEL_FILES = ["BUILD", "BUILD.bazel", "MODULE.bazel", "REPO.bazel", "WORKSPACE", "WORKSPACE.bazel", "WORKSPACE.bzlmod"]

def _repository_root(ctx, lock):
    path = ctx.path(lock)
    for _ in (lock.package + "/" + lock.name if lock.package else lock.name).split("/"):
        path = path.dirname
    return path

def _walk(directory, parts):
    for part in parts:
        if part == "..":
            directory = directory.dirname or directory
        elif part:
            directory = directory.get_child(part)
    return directory

def pub_lock_path_directory(ctx, lock, path):
    """The directory of a `path` package, from the lock that lists it.

    As pub does, the path is resolved lexically against the lock's directory,
    with `/` or `\\` between its parts. An absolute path is taken as it is. A
    relative one leaving the lock's repository starts from where the
    repository really is, which for one `local_path_override` brings in is not
    where Bazel shows it. A Windows path on another system names nothing here,
    so it gives a directory that does not exist.

    Args:
        ctx: The `repository_ctx` or `module_ctx`.
        lock: The lock's `Label`.
        path: The entry's `description.path`.

    Returns:
        The directory's `path`. It need not exist.
    """
    normalized = normalize_pub_path(path)
    root = pub_path_root(normalized)
    if root:
        foreign = root[1:2] == ":" and not ctx.os.name.lower().startswith("windows")
        return ctx.path("/" + normalized if foreign else normalized)
    from_root = lock_path_in_repo(lock, path)
    if from_root == ".." or from_root.startswith("../"):
        return _walk(_repository_root(ctx, lock).realpath, from_root.split("/"))
    return _walk(ctx.path(lock).dirname, normalized.split("/"))

def _canonical(path):
    # Its absolute path with links resolved. As for pub, what does not exist
    # counts as a plain directory, so a package not there yet still has a place.
    missing = []
    existing = path
    for _ in range(4096):
        parent = existing.dirname
        if existing.exists or parent == None:
            break
        missing.insert(0, existing.basename)
        existing = parent
    return "/".join([str(existing.realpath).rstrip("/")] + missing) or "/"

def pub_lock_path_location(ctx, lock, path):
    """Where a `path` package's directory is on this machine, to compare two by.

    Args:
        ctx: The `repository_ctx` or `module_ctx`.
        lock: The lock's `Label`.
        path: The entry's `description.path`.

    Returns:
        The directory's absolute path with symbolic links resolved, as a
        string. Two entries naming one directory, however each spells it, give
        one location.
    """
    return _canonical(pub_lock_path_directory(ctx, lock, path))

def _below(location, root):
    # `location` from `root`, or None when it is not there.
    if location == root:
        return ""
    return location[len(root) + 1:] if location.startswith(root + "/") else None

def pub_lock_path_source(rctx, lock, path):
    """Where a `path` package built from its directory came from, on this machine.

    For a directory inside the lock's repository, `pub_path_source`. For one
    outside it, the same name when the path leads back into the lock's
    repository or the main repository, so it is one package with what a lock
    there builds; otherwise the directory's location
    (`pub_lock_path_location`), which no other machine shares a meaning for
    and no repository carries to one.

    Args:
        rctx: The `repository_ctx`.
        lock: The lock's `Label`.
        path: The entry's `description.path`.

    Returns:
        The source (`pub_hosted_source`).
    """
    source = pub_path_source(lock, path)
    if source != None:
        return source
    location = pub_lock_path_location(rctx, lock, path)
    for repository, root in ((lock.repo_name, _repository_root(rctx, lock)), ("", rctx.workspace_root)):
        directory = _below(location, _canonical(root))
        if directory != None:
            return pub_directory_source(repository, directory)
    return pub_directory_source("", location)

def _check_entry(entry):
    parts = entry.split("/")
    if entry.startswith("/") or "\\" in entry or [p for p in parts if p in ("", ".", "..")]:
        fail("link_pub_path: `%s` is not a relative path inside the package: name each entry by its path below the package directory, with `/` between its parts." % entry)
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

def link_pub_path(rctx, directory, entries):
    """Links the named entries of a local package directory into the repository.

    Args:
      rctx: The repository context.
      directory: The package directory, a `path`, as
        `pub_lock_path_directory` finds it from the lock.
      entries: Paths below `directory` to serve, such as `pubspec.yaml`, `lib`
        or `android/src`. Each is linked at its own path, a missing one is
        skipped, and every one is watched.

    Returns:
      None, or why the package cannot be built from this directory, for the
      caller to make the builds using it fail with. Nothing is linked then, and
      what was looked at is still watched, so fixing it refetches the repository.
    """
    root = rctx.path(directory)
    rctx.watch(root)
    if not root.exists:
        return ("The package directory %s does not exist. The lock lists the package by " +
                "path; check out that directory, or name the package in `resolve` or " +
                "`ignored` instead.") % root
    if not root.is_dir:
        return "%s is not a directory." % root
    links = []
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
        links.append((src, entry))
    if found:
        return ("%s has a Bazel build of its own (%s). Map the package to the target that " +
                "builds it, with `resolve`, instead of building it from its pubspec.") % (root, ", ".join(found))
    for src, entry in links:
        rctx.symlink(src, entry)
    return None
