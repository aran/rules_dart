"""Fetches a git-sourced pub package into a repository.

`pub.from_lock()`'s `pub_lock_git_package` and rules_flutter's
`flutter_pub_package` fetch a lock's `source: git` entries through
`fetch_pub_git`, so one locked commit is the same tree whichever rule asks.

The tree is what `dart pub get` checks out on a host with no git
configuration of its own, whatever the host has:

- **Fetching** uses the host's git and its configuration, so credential
  helpers, `url.<base>.insteadOf` mirrors and proxies work as they do for
  `dart pub get`, and so do the variables that carry them (`GIT_SSH_COMMAND`,
  `GIT_ASKPASS`, `GIT_TERMINAL_PROMPT`, `GIT_CONFIG_COUNT` with its
  `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>`, `GIT_CONFIG_PARAMETERS`).
  It asks for the locked commit alone; a server that refuses to fetch by
  commit id is asked for every ref it advertises instead, which is what pub
  fetches. Nothing the fetch is given can change the files: the commit is
  named by its full id and checked afterwards, and the next step writes them.
- **Writing the files** reads none of the host's configuration: no system or
  global config, no line-ending conversion, no filters, no hooks. Attributes
  in the repository apply (`eol=crlf`, `-text`), from every `.gitattributes`
  in the locked commit, as they do for pub.
- The client's `GIT_*` variables, which Bazel passes to repository rules, do
  not move the repository. Writing the files unsets all of them. Fetching
  unsets those git lists as locating a repository (`git rev-parse
  --local-env-vars`, as Bazel's `git_repository` does), except the two that
  carry configuration, which is how CI hands git its credentials.

The result depends only on the lock entry, so a rule calling this can return
`rctx.repo_metadata(reproducible = True)` when nothing else it does reads the
host.
"""

load("//dart/pub/private:pub_archive.bzl", "drop_escaping_links")

visibility("//dart/...")

# pub's own floor (`_minSupportedGitVersion`): older gits are not known to
# behave as this asks.
MIN_GIT_VERSION = (2, 14)

_HEX = "0123456789abcdef"
_DIGITS = "0123456789"
_SCHEME = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-"

# Scratch space inside the repository, removed before the fetch returns.
_SCRATCH = "_pub_git_fetch"

def is_git_commit_id(ref):
    """Whether `ref` is a full commit id as git writes one: 40 lowercase hex digits.

    Args:
        ref: The `resolved-ref` as the lock states it.

    Returns:
        True for exactly 40 characters of `0-9a-f`.
    """
    if len(ref) != 40:
        return False
    for ch in ref.elems():
        if ch not in _HEX:
            return False
    return True

def pub_git_resolved_ref_error(package_name, version, resolved_ref, declared_in, rewrite = None):
    """Why `resolved_ref` does not pin one commit, or None when it does.

    A branch, a tag or an abbreviated id names whatever commit it names on the
    day of the fetch, so the package would be whatever the server holds then.
    Ask where the entry is first read, so the message names where it was
    declared.

    Args:
        package_name: The pub package name.
        version: The package version.
        resolved_ref: The lock entry's `description.resolved-ref`.
        declared_in: Where the entry was declared, for the message.
        rewrite: The command that re-resolves the lock, printed on a line of
            its own; None where it is not known.

    Returns:
        The message, or None for a full commit id.
    """
    if is_git_commit_id(resolved_ref):
        return None
    return ("The git package \"{name}\" {version} (in {where}) is locked at resolved-ref " +
            "\"{ref}\", which is not a full commit id (40 lowercase hex digits), so it " +
            "does not pin what is fetched and will not be fetched. Re-resolve the lock, " +
            "from the root of the workspace that holds it, and pub records the commit it " +
            "resolved as `resolved-ref`{colon}{rewrite}").format(
        name = package_name,
        version = version,
        where = declared_in,
        ref = resolved_ref,
        colon = ":\n  " if rewrite else ".",
        rewrite = rewrite or "",
    )

def check_pub_git_resolved_ref(package_name, version, resolved_ref, declared_in, rewrite = None):
    """Fails with `pub_git_resolved_ref_error`'s message unless `resolved_ref` pins one commit.

    Args:
        package_name: The pub package name.
        version: The package version.
        resolved_ref: The lock entry's `description.resolved-ref`.
        declared_in: Where the entry was declared, for the message.
        rewrite: The command that re-resolves the lock; None where it is not
            known.
    """
    error = pub_git_resolved_ref_error(package_name, version, resolved_ref, declared_in, rewrite)
    if error:
        fail(error)

def is_relative_git_url(url):
    """Whether a lock's git `url` is a path relative to the lock, as pub reads it.

    pub writes a repository its pubspec names by a relative path relative to
    the lock's directory. Anything with a scheme, an scp-style SSH address
    (`git@host:path`) or an absolute path is not relative.

    Args:
        url: The lock entry's `description.url`.

    Returns:
        True for a relative path.
    """
    at = url.find("@")
    colon = url.find(":")
    if at != -1 and (colon == -1 or at < colon):
        return False
    if url.startswith("/"):
        return False
    if colon > 0 and url[0].isalpha():
        scheme = url[:colon]
        if all([ch in _SCHEME for ch in scheme.elems()]):
            return False
    return True

def git_fetch_url(url, windows):
    """The URL to hand git for a lock's git `url`.

    git reads a `file:` URL with an empty host, `file:///D:/r`, as the path
    `/D:/r`, which names no drive on Windows unless MSYS rewrites it (and
    Bazel's Windows setup turns that off); it reads `file://D:/r` as the
    drive path. Elsewhere `/D:/r` is a path like any other.

    Args:
        url: The lock entry's `description.url`.
        windows: Whether git runs on Windows.

    Returns:
        `url`, in the two-slash form for a Windows drive.
    """
    prefix = "file:///"
    rest = url[len(prefix):]
    if (windows and url.lower().startswith(prefix) and len(rest) >= 3 and
        rest[0].isalpha() and rest[1] == ":" and rest[2] in "/\\"):
        return url[:len(prefix) - 1] + rest
    return url

def parse_git_version(text):
    """Reads `git --version` output.

    Args:
        text: What `git --version` printed.

    Returns:
        `(major, minor)`, or None if `text` does not read as a git version.
    """
    prefix = "git version "
    text = text.strip()
    if not text.startswith(prefix):
        return None
    parts = text[len(prefix):].split(" ")[0].split(".")
    if len(parts) < 2:
        return None
    for part in parts[:2]:
        if not part or not all([ch in _DIGITS for ch in part.elems()]):
            return None
    return (int(parts[0]), int(parts[1]))

# Carry configuration, not a location, though git lists them as repository
# variables (so that a command run for a repository does not hand its
# configuration to another). A fetch needs them: CI injects credentials and
# mirrors through them. `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` are
# not listed and are read only with the count.
_CONFIG_VARS = ["GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"]

# Not a location, but git refuses it empty, which is how a client unsets it
# through `--repo_env`.
_ALSO_UNSET = ["GIT_ATTR_SOURCE"]

def fetch_unset_vars(client_vars, local_env_vars):
    """Which of the client's variables a `git fetch` must not see.

    Those that say where the repository is, which would send the fetch into
    the client's repository instead of the one it was told to fill. Every
    other variable reaches the fetch, so the transport and credential
    settings in them apply.

    Args:
        client_vars: Names of the variables the client passed.
        local_env_vars: What `git rev-parse --local-env-vars` printed: one
            name per line.

    Returns:
        A dict from each name to unset to None, for `rctx.execute`'s
        `environment`. Names compare without regard to case, as on Windows.
    """
    local = {}
    for name in local_env_vars.replace("\r", "").split("\n"):
        name = name.strip().upper()
        if name and name not in _CONFIG_VARS:
            local[name] = True
    for name in _ALSO_UNSET:
        local[name] = True
    return {name: None for name in client_vars if name.upper() in local}

def _run(rctx, what, args, environment):
    result = rctx.execute(args, environment = environment, quiet = True)
    if result.return_code != 0:
        fail("{} failed (exit {}):\n{}{}".format(what, result.return_code, result.stdout, result.stderr))
    return result

def fetch_pub_git(rctx, package_name, version, url, resolved_ref, path = ".", lock = None):
    """Fetches a git package's locked commit and lays out its directory at the repository root.

    Args:
        rctx: The `repository_ctx`.
        package_name: The pub package name, for messages.
        version: The package version, for messages.
        url: The lock entry's `description.url`.
        resolved_ref: The lock entry's `description.resolved-ref`, a full commit id.
        path: The lock entry's `description.path`: the package's directory in
            the repository.
        lock: The lock's label, against whose directory a relative `url` is
            resolved, as pub resolves it. Needed only for a relative `url`.
    """
    what = "git package \"{}\" {} (@{})".format(package_name, version, rctx.original_name)
    check_pub_git_resolved_ref(package_name, version, resolved_ref, "@" + rctx.original_name)
    if is_relative_git_url(url):
        if lock == None:
            fail("The {} is locked with the relative url \"{}\", and no lock is given to resolve it against.".format(what, url))
        url = str(rctx.path(lock).dirname) + "/" + url

    git = rctx.which("git")
    if git == None:
        fail("Fetching the {} needs git, and none is on PATH.".format(what))
    git = str(git)

    # Bazel hands the client's environment to repository rules. Writing the
    # files, and every question asked of git's own repository, sees none of
    # the GIT_* variables. They are unset, not emptied: git refuses some
    # empty values outright (GIT_ATTR_SOURCE).
    unset = {var: None for var in rctx.os.environ if var.upper().startswith("GIT_")}

    found = parse_git_version(_run(rctx, "`git --version`", [git, "--version"], unset).stdout)
    if found == None or found < MIN_GIT_VERSION:
        fail("Fetching the {} needs git {}.{} or newer, as `dart pub get` does; {} is {}.".format(
            what,
            MIN_GIT_VERSION[0],
            MIN_GIT_VERSION[1],
            git,
            "%d.%d" % found if found else "not a version git reports",
        ))

    # Host configuration cut off: no system or global config, and an empty
    # home for git to look in.
    scratch = rctx.path(_SCRATCH)
    rctx.file(_SCRATCH + "/home/.keep", "", executable = False)
    rctx.file(_SCRATCH + "/hooks/.keep", "", executable = False)
    rctx.file(_SCRATCH + "/attributes", "", executable = False)
    isolated = dict(unset)
    isolated.update({
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": str(scratch.get_child("home")),
        "XDG_CONFIG_HOME": str(scratch.get_child("home")),
    })
    git_dir = str(scratch.get_child("repo.git"))
    tree = scratch.get_child("tree")
    in_repo = [git, "--git-dir=" + git_dir]
    isolated_git = in_repo + [
        "--work-tree=" + str(tree),
        "--literal-pathspecs",
        "-c",
        "core.bare=false",
        "-c",
        "core.autocrlf=false",
        "-c",
        "core.eol=lf",
        "-c",
        "core.symlinks=true",
        "-c",
        "core.hooksPath=" + str(scratch.get_child("hooks")),
        "-c",
        "core.attributesFile=" + str(scratch.get_child("attributes")),
    ]

    # Made without the host's configuration, which could choose the object
    # format or copy in hooks.
    _run(rctx, "`git init`", [git, "init", "-q", "--bare", "--template=", git_dir], isolated)

    # Transport with the host's configuration: its credentials and mirrors,
    # in its files and in its variables. Only the variables that locate a
    # repository are unset, as this git lists them (`git_repository` does the
    # same): the list differs between versions. The commit is named by its
    # full id and checked below, and the files are written without the
    # variables, so none of them can change what lands in the repository.
    local_env_vars = _run(rctx, "`git rev-parse --local-env-vars`", [git, "rev-parse", "--local-env-vars"], unset).stdout
    for_fetch = fetch_unset_vars(rctx.os.environ.keys(), local_env_vars)
    fetch_url = git_fetch_url(url, rctx.os.name.startswith("windows"))
    by_id = rctx.execute(in_repo + ["fetch", "-q", "--depth=1", "--no-tags", "--", fetch_url, resolved_ref], environment = for_fetch, quiet = True)
    if by_id.return_code != 0:
        # The server refuses to fetch by commit id (protocol v0, a
        # dumb transport). Fetch every ref it advertises, as pub does.
        every_ref = rctx.execute(in_repo + ["fetch", "-q", "--no-tags", "--", fetch_url, "+refs/*:refs/*"], environment = for_fetch, quiet = True)
        if every_ref.return_code != 0:
            fail("Fetching the {} from {} failed. Fetching commit {} gave:\n{}\nFetching every ref gave:\n{}".format(
                what,
                url,
                resolved_ref,
                by_id.stderr,
                every_ref.stderr,
            ))

    commit = rctx.execute(in_repo + ["rev-parse", "--verify", "--quiet", resolved_ref + "^{commit}"], environment = isolated, quiet = True)
    if commit.return_code != 0 or commit.stdout.strip() != resolved_ref:
        fail(("The {} is locked at commit {}, which {} does not serve: it is on no ref the " +
              "server advertises, and the server does not fetch by commit id. Upgrade the " +
              "package in the lock that lists it (pub's `upgrade {}`) to lock a commit that " +
              "is there.").format(what, resolved_ref, url, package_name))
    if path != ".":
        subtree = rctx.execute(in_repo + ["cat-file", "-t", "{}:{}".format(resolved_ref, path)], environment = isolated, quiet = True)
        if subtree.return_code != 0 or subtree.stdout.strip() != "tree":
            fail("The {} is locked at path \"{}\", which is not a directory in commit {} of {}.".format(what, path, resolved_ref, url))

    # git writes only into a work tree that exists.
    rctx.file(_SCRATCH + "/tree/.keep", "", executable = False)
    rctx.delete(_SCRATCH + "/tree/.keep")

    # The whole commit goes in the index, so every .gitattributes in it
    # applies, the root's too; only the package's directory is written.
    _run(rctx, "`git read-tree`", isolated_git + ["read-tree", resolved_ref], isolated)
    _run(rctx, "`git checkout`", isolated_git + ["checkout", "-q", "-f", "--", path], isolated)

    package = tree if path == "." else tree.get_child(path)
    for child in package.readdir():
        rctx.rename(child, child.basename)
    rctx.delete(scratch)

    # The package is served without the rest of the repository, so a link
    # out of it has nothing to point at.
    drop_escaping_links(rctx)
