"""Fetches a hosted pub package's archive into a repository.

Every repository rule that materialises a hosted pub package — `pub_lock_package`
(`pub.from_lock()`), `pub_package` (`pub.package()`) and rules_flutter's
`flutter_pub_package` — fetches through `fetch_pub_archive`, so one package
version is fetched and laid out the same way whichever rule asks for it.
"""

visibility("//dart/...")

_ARCHIVE = "_pub_archive.tar.gz"

# tar.bzl's prebuilt bsdtar, one repository per host. These labels resolve in
# rules_dart's repository mapping, whichever module's rule fetches.
_BSDTAR = {
    "darwin_amd64": Label("@bsd_tar_toolchains_darwin_amd64//:tar"),
    "darwin_arm64": Label("@bsd_tar_toolchains_darwin_arm64//:tar"),
    "linux_amd64": Label("@bsd_tar_toolchains_linux_amd64//:tar"),
    "linux_arm64": Label("@bsd_tar_toolchains_linux_arm64//:tar"),
    "windows_amd64": Label("@bsd_tar_toolchains_windows_amd64//:tar.exe"),
    "windows_arm64": Label("@bsd_tar_toolchains_windows_arm64//:tar.exe"),
}

# bsdtar converts entry names through the locale. These are the UTF-8 locales
# tar.bzl's own toolchain sets; macOS has no C.UTF-8.
_UTF8_LOCALE = "C.UTF-8"
_UTF8_LOCALE_MACOS = "en_US.UTF-8"

def _host_bsdtar(rctx):
    """The host's bsdtar; only its repository is fetched."""
    name = rctx.os.name.lower()
    arch = rctx.os.arch.lower()
    if name.startswith("mac"):
        os = "darwin"
    elif name.startswith("windows"):
        os = "windows"
    elif name.startswith("linux"):
        os = "linux"
    else:
        os = name
    if arch in ("aarch64", "arm64"):
        cpu = "arm64"
    elif arch in ("amd64", "x86_64", "x64"):
        cpu = "amd64"
    else:
        cpu = arch
    host = os + "_" + cpu
    if host not in _BSDTAR:
        fail("rules_dart extracts pub packages with tar.bzl's bsdtar, which has no build for this host ({} {}).".format(
            rctx.os.name,
            rctx.os.arch,
        ))
    return rctx.path(_BSDTAR[host])

def tar_entry_leaves_package(entry):
    """Whether a tar entry's name is absolute or climbs out through `..`.

    Args:
        entry: The entry's name, as `bsdtar -t` lists it.

    Returns:
        True for a name that starts at a root (`/`, `\\`, a drive letter) or
        has a `..` segment.
    """
    if entry.startswith("/") or entry.startswith("\\"):
        return True
    if len(entry) >= 2 and entry[1] == ":" and entry[0].isalpha():
        return True
    return ".." in entry.replace("\\", "/").split("/")

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

def pub_archive_sha256_error(package_name, version, sha256, declared_in, rewrite = None, base_url = "https://pub.dev"):
    """Why `sha256` does not pin the package's archive, or None when it does.

    An empty `sha256` means "do not check" to Bazel's downloader, so a lock entry
    without one (written by a pub older than 2.19, or edited by hand) would be
    fetched on trust. A digest of the wrong shape (short, not hex, an SRI
    string) would only fail after the request. Ask where the digest is first
    read, so the message names where it was declared.

    Args:
        package_name: The pub package name.
        version: The package version.
        sha256: The archive digest as declared.
        declared_in: Where the digest was declared, for the message: a lock
            file's label, or `pub.package()`.
        rewrite: The command that re-resolves the lock it was declared in,
            printed on a line of its own. None where it was not declared in a
            lock, or the command is not known.
        base_url: The hosted registry, whose API gives the digest where
            there is no lock to re-resolve.

    Returns:
        The message, or None for a digest of the shape pubspec.lock records.
    """
    if is_pub_sha256(sha256):
        return None
    if rewrite:
        remedy = ("Re-resolve the lock, from the root of the workspace that holds it, " +
                  "and pub records the digest:\n  " + rewrite)
    else:
        remedy = ("The registry gives it as `archive_sha256` in:\n  {api}/api/packages/{name}/versions/{version}").format(
            api = base_url.rstrip("/"),
            name = package_name,
            version = version,
        )
    if not sha256:
        return ("No sha256 is pinned for pub package \"{name}\" {version} (in {where}), so its " +
                "archive cannot be verified and will not be fetched. {remedy}").format(
            name = package_name,
            version = version,
            where = declared_in,
            remedy = remedy,
        )
    return ("The sha256 for pub package \"{name}\" {version} (in {where}) is \"{sha256}\", " +
            "which is not a SHA-256 as pubspec.lock records one (64 lowercase hex digits), " +
            "so its archive will not be fetched. {remedy}").format(
        name = package_name,
        version = version,
        where = declared_in,
        sha256 = sha256,
        remedy = remedy,
    )

def check_pub_archive_sha256(package_name, version, sha256, declared_in, rewrite = None, base_url = "https://pub.dev"):
    """Fails with `pub_archive_sha256_error`'s message unless `sha256` pins the package's archive.

    Args:
        package_name: The pub package name.
        version: The package version.
        sha256: The archive digest as declared.
        declared_in: Where the digest was declared, for the message.
        rewrite: The command that re-resolves the lock it was declared in;
            None where it is not known.
        base_url: The hosted registry.
    """
    error = pub_archive_sha256_error(package_name, version, sha256, declared_in, rewrite, base_url)
    if error:
        fail(error)

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
    `check_pub_archive_sha256`). It is extracted with tar.bzl's prebuilt bsdtar
    for the host, never a `tar` from the host, and not with Bazel's extractor,
    because pub.dev serves some archives (`nested` 1.0.0, among others) with
    padding after the gzip stream, which Bazel's extractor rejects and pub
    accepts. An archive with an entry named by an absolute path or through
    `..` is refused, as pub refuses it. After extraction, symlinks that leave
    the package are deleted, as pub does.

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
    check_pub_archive_sha256(package_name, version, sha256, "@" + rctx.name, base_url = base_url)
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = base_url.rstrip("/"),
        name = package_name,
        version = version,
    )
    rctx.download(url = url, output = _ARCHIVE, sha256 = sha256)
    tar = _host_bsdtar(rctx)
    env = {"LC_ALL": _UTF8_LOCALE_MACOS if rctx.os.name.lower().startswith("mac") else _UTF8_LOCALE}

    def run(args, what):
        result = rctx.execute([tar] + args, environment = env)
        if result.return_code != 0:
            fail("{what} pub package \"{name}\" {version} from {url} with bsdtar failed:\n{out}{err}".format(
                what = what,
                name = package_name,
                version = version,
                url = url,
                out = result.stdout,
                err = result.stderr,
            ))
        return result.stdout

    # bsdtar would strip a leading `/` and extract the rest inside the package;
    # pub refuses such an archive, so it is refused here before extraction.
    # `bsdtar -t` escapes control characters, so each line is one entry.
    for entry in run(["-tzf", _ARCHIVE], "Listing").splitlines():
        if tar_entry_leaves_package(entry):
            fail(("Pub package \"{name}\" {version} from {url} has an entry \"{entry}\" " +
                  "that names a path outside the package, so it is not extracted.").format(
                name = package_name,
                version = version,
                url = url,
                entry = entry,
            ))
    run(["-xzf", _ARCHIVE], "Extracting")
    rctx.delete(_ARCHIVE)
    drop_escaping_links(rctx)
