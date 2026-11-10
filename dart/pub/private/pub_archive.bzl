"""Fetches a hosted pub package's archive into a repository.

Every repository rule that materialises a hosted pub package — `pub_lock_package`
(`pub.from_lock()`), `pub_package` (`pub.package()`) and rules_flutter's
`flutter_pub_package` — fetches through `fetch_pub_archive`, so one package
version is fetched and laid out the same way whichever rule asks for it.
"""

_ARCHIVE = "_pub_archive.tar.gz"

_HEX = "0123456789abcdef"

def is_pub_sha256(sha256):
    """Whether `sha256` is a digest as pubspec.lock records one: 64 lowercase hex digits.

    Args:
        sha256: The digest as declared.

    Returns:
        True for exactly 64 characters of `0-9a-f`.
    """
    if len(sha256) != 64:
        return False
    for ch in sha256.elems():
        if ch not in _HEX:
            return False
    return True

def check_pub_archive_sha256(package_name, version, sha256, declared_in):
    """Fails unless `sha256` pins the package's archive.

    An empty `sha256` means "do not check" to Bazel's downloader, so a lock entry
    without one (written by a pub older than 2.19, or edited by hand) would be
    fetched on trust. A digest of the wrong shape (short, not hex, an SRI
    string) would only fail after the request. Call this where the digest is
    first read, so the error names where it was declared.

    Args:
        package_name: The pub package name.
        version: The package version.
        sha256: The archive digest as declared.
        declared_in: Where the digest was declared, for the message: a lock
            file's label, or `pub.package()`.
    """
    if is_pub_sha256(sha256):
        return
    if not sha256:
        fail(("No sha256 is pinned for pub package \"{name}\" {version} (in {where}), so its " +
              "archive cannot be verified and will not be fetched. Run `dart pub get` " +
              "(Dart 2.19 or newer) to record each package's digest in pubspec.lock as " +
              "`description.sha256`.").format(
            name = package_name,
            version = version,
            where = declared_in,
        ))
    fail(("The sha256 for pub package \"{name}\" {version} (in {where}) is \"{sha256}\", " +
          "which is not a SHA-256 as pubspec.lock records one (64 lowercase hex digits), " +
          "so its archive will not be fetched. Run `dart pub get` to rewrite it, or copy " +
          "the digest pub.dev lists for that version.").format(
        name = package_name,
        version = version,
        where = declared_in,
        sha256 = sha256,
    ))

def drop_escaping_links(rctx):
    """Deletes every symlink in the repository that leaves it or dangles.

    pub's own extraction skips a link whose target leaves the package. This
    reads only the extracted tree, so it does not depend on which `tar`
    extracted it. A link is judged by where it finally resolves, so a chain
    through an in-package link is caught too. A dangling link cannot be
    resolved and points at nothing in the package, so it goes as well.

    Args:
        rctx: The `repository_ctx` whose files to check.
    """
    root = rctx.path(".")
    real_root = str(root.realpath)

    # Directories to visit, as paths relative to the root. Starlark has no
    # recursion or `while`, so the walk is a stack drained by the longest loop
    # Starlark allows: one turn per directory.
    pending = [""]
    for _ in range(2147483647):
        if not pending:
            break
        rel = pending.pop()
        directory = root.get_child(rel) if rel else root
        for child in directory.readdir():
            child_rel = rel + "/" + child.basename if rel else child.basename
            if not child.exists:
                rctx.delete(child)
                continue
            real = str(child.realpath)
            if real != real_root + "/" + child_rel:
                # A symlink. Kept when it resolves inside the package; never
                # walked into, so a link to an ancestor cannot loop.
                if real != real_root and not real.startswith(real_root + "/"):
                    rctx.delete(child)
            elif child.is_dir:
                pending.append(child_rel)

def fetch_pub_archive(rctx, package_name, version, sha256, base_url = "https://pub.dev"):
    """Downloads a hosted pub package and extracts it at the repository root.

    The archive is fetched from `<base_url>/packages/<name>/versions/<version>.tar.gz`
    and checked against `sha256`, which must be set (see
    `check_pub_archive_sha256`). It is extracted with the host `tar` (bsdtar on
    macOS and Windows 10+, GNU tar on Linux) rather than Bazel's extractor,
    because pub.dev serves some archives (`nested` 1.0.0, among others) with
    padding after the gzip stream, which Bazel's extractor rejects and pub
    accepts. After extraction, symlinks that leave the package are deleted, as
    pub does.

    The result depends only on the arguments, so a rule calling this can return
    `rctx.repo_metadata(reproducible = True)` when nothing else it does reads
    the host.

    Args:
        rctx: The `repository_ctx`.
        package_name: The pub package name.
        version: The package version.
        sha256: The archive's SHA-256, as pubspec.lock records it.
        base_url: The hosted registry, as pubspec.lock's `description.url`.
    """
    check_pub_archive_sha256(package_name, version, sha256, "@" + rctx.name)
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = base_url.rstrip("/"),
        name = package_name,
        version = version,
    )
    rctx.download(url = url, output = _ARCHIVE, sha256 = sha256)
    result = rctx.execute(["tar", "-xzf", _ARCHIVE])
    if result.return_code != 0:
        fail("Extracting pub package \"{name}\" {version} from {url} with `tar -xzf` failed:\n{out}{err}".format(
            name = package_name,
            version = version,
            url = url,
            out = result.stdout,
            err = result.stderr,
        ))
    rctx.delete(_ARCHIVE)
    drop_escaping_links(rctx)
