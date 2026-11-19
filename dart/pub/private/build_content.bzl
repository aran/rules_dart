"""The BUILD file shape every pub spoke repository carries.

`pub.package()` and `pub.from_lock()` each materialise a pub.dev package as
its own repository holding a single `dart_library`. Both emit that target
through the one generator here, so a field added to the shape reaches both
paths instead of only the one whose template was edited.

Every spoke's library says `runtime_independent = True`: a pub package
cannot `select()` on the runtime constraint,
`@rules_dart//dart/constraints:runtime`, so it is built once however many
web compilers reach it.
"""

load("@package_metadata//purl:purl.bzl", "purl")
load("//dart/private:package_info.bzl", "directory_identity", "local_git_identity", "purl_identity")
load("//dart/pub/private:hosted_url.bzl", "normalize_hosted_url")
load("//dart/pub/private:pub_git.bzl", "is_relative_git_url")

visibility("//dart/...")

# The `package_metadata` target a fetched package's repository attaches to
# every target in it. Not a Dart package name, so no library can be called it.
_IDENTITY_TARGET = "package-metadata"

# The `dart_package_metadata` of a fetched package, which its library names.
# The library is called after the package, and this is not a Dart package
# name, so the two never collide.
_METADATA_TARGET = "pubspec-metadata"

def is_pub_dev(url):
    """Whether a lock's hosted `url` is pub.dev, however pub would spell it.

    pub.dev is what a purl of type `pub` means when it names no
    `repository_url` (the purl spec's default is its older name).

    Args:
        url: The registry, as pubspec.lock's `description.url`.

    Returns:
        True for pub.dev.
    """
    return normalize_hosted_url(url) == "https://pub.dev"

def pub_hosted_purl(name, version, sha256, base_url = "https://pub.dev"):
    """The purl of a hosted pub package's archive.

    `pkg:pub/<name>@<version>?checksum=sha256:<hex>`, with the registry as
    `repository_url` when it is not pub.dev.

    Args:
        name: The pub package name.
        version: The package version.
        sha256: The archive's SHA-256, as pubspec.lock records it.
        base_url: The hosted registry, as pubspec.lock's `description.url`.

    Returns:
        The purl, as the `package_metadata` module's builder writes it.
    """
    builder = purl.builder().type("pub").name(name).version(version)
    builder.add_qualifier("checksum", "sha256:" + sha256)
    if not is_pub_dev(base_url):
        builder.add_qualifier("repository_url", base_url.rstrip("/"))
    return builder.build()

def pub_git_purl(name, version, url, resolved_ref, path = "."):
    """The purl of a git pub package at its locked commit.

    `pkg:pub/<name>@<version>?vcs_url=git+<url>@<commit>`, with `#<path>`
    for a package in a subdirectory, as an SPDX VCS location writes it. The
    path is normalized (`normalize_pub_path`), so every spelling of one
    directory names it alike. The url is the lock's as written, a relative
    one too: an SBOM then lists the package by its name, version and
    commit, with a location that says it is a path from the lock's
    checkout. A relative url names its repository only together with its
    lock, so whether two copies are one package is `pub_git_source`'s to
    say.

    Args:
        name: The pub package name.
        version: The package version.
        url: The lock entry's `description.url`.
        resolved_ref: The locked commit: `description.resolved-ref`.
        path: The lock entry's `description.path`.

    Returns:
        The purl, as the `package_metadata` module's builder writes it.
    """
    location = "git+{}@{}".format(url, resolved_ref) + _git_subdirectory(path)
    return purl.builder().type("pub").name(name).version(version).add_qualifier("vcs_url", location).build()

def pub_hosted_source(name, version, sha256, base_url = "https://pub.dev"):
    """Where a hosted pub package came from: its archive.

    A source is what a fetcher's generated BUILD file states about a package,
    and what `make_package_metadata_content`, the other generators and
    `pub_package_identity` take: `struct(identity, purl)`. `identity` is what
    the package was fetched as (`DartPackageInfo.fetched_identity`), or None
    when nothing names that; `purl` is what an SBOM lists it as, or "". Make one
    with this, `pub_git_source` or `pub_path_source`, which keep the two
    consistent. No source at all is None.

    Args:
        name: The pub package name.
        version: The package version.
        sha256: The archive's SHA-256, as pubspec.lock records it.
        base_url: The hosted registry, as pubspec.lock's `description.url`.

    Returns:
        The source: its identity is the archive's purl (`pub_hosted_purl`).
    """
    package_purl = pub_hosted_purl(name, version, sha256, base_url)
    return struct(identity = purl_identity(package_purl), purl = package_purl)

def pub_git_source(name, version, url, resolved_ref, path = ".", lock = None):
    """Where a git pub package came from: its locked commit.

    Its purl is `pub_git_purl`'s. For a url naming the repository on its own,
    that is its identity too. A relative url (`is_relative_git_url`) names a
    repository in the lock's repository, where the same text relative to two
    locks names two: the identity is that repository, found from the lock as
    `pub_path_source` finds a path package's directory, with the commit and
    the path. Two locks naming one repository, however each spells it, state
    one identity, and two naming different ones never do. A relative url
    leaving the lock's repository has no such name: the source has no
    identity, and still its purl, so an SBOM lists the package.

    Args:
        name: The pub package name.
        version: The package version.
        url: The lock entry's `description.url`.
        resolved_ref: The locked commit: `description.resolved-ref`.
        path: The lock entry's `description.path`.
        lock: The lock's `Label`; needed only for a relative url.

    Returns:
        The source (`pub_hosted_source`).
    """
    package_purl = pub_git_purl(name, version, url, resolved_ref, path)
    if not is_relative_git_url(url):
        return struct(identity = purl_identity(package_purl), purl = package_purl)
    if lock == None:
        fail("The git package \"{}\" {} is locked with the relative url \"{}\", and no lock is given to resolve it against.".format(name, version, url))
    directory = lock_path_in_repo(lock, url)
    if directory == ".." or directory.startswith("../"):
        return struct(identity = None, purl = package_purl)
    return struct(
        identity = local_git_identity(lock.repo_name, directory, resolved_ref, normalize_pub_path(path)),
        purl = package_purl,
    )

def _git_subdirectory(path):
    directory = normalize_pub_path(path)
    return "#" + directory if directory else ""

def normalize_pub_path(path):
    """A path as pub reads it, `/`-separated, with `.` and `..` collapsed.

    A `..` that would leave the path's start is kept, so a path leaving the
    directory it is relative to still says so.

    Args:
        path: A path, `/`- or `\\`-separated.

    Returns:
        The path, without empty or `.` segments; "" for the directory itself.
    """
    absolute = path.startswith("/")
    parts = []
    for part in path.replace("\\", "/").split("/"):
        if part in ("", "."):
            continue
        if part == ".." and parts and parts[-1] != "..":
            parts.pop()
        else:
            parts.append(part)
    return ("/" if absolute else "") + "/".join(parts)

def lock_path_in_repo(lock, path):
    """A lock's relative `path`, from the root of the lock's repository.

    Args:
        lock: The lock's `Label`.
        path: The lock entry's `description.path`, relative to the lock's
            directory.

    Returns:
        The path, normalized (`normalize_pub_path`); it starts with `..` when
        it leaves the repository.
    """

    # The lock's directory, from its package and its name: a lock named
    # `sub/pubspec.lock` sits in the package's `sub/`.
    directory = (lock.package + "/" + lock.name if lock.package else lock.name).rpartition("/")[0]
    return normalize_pub_path(directory + "/" + path if directory else path)

def pub_path_source(lock, path):
    """Where a `path` package built from its directory came from: that directory.

    The identity is the repository holding the lock and the directory's path
    from that repository's root. It is the same on every machine and for every
    lock naming the directory, however each spells the path (`./`, a trailing
    `/`, `..`), so two fetchers building one directory state one identity, as
    two fetching one archive state one purl.

    It has no purl: its files are the lock's repository's own, which is where
    they came from, so the repository's own supply-chain metadata, if any, is
    theirs. The purl spec has no type for a directory, and a second origin
    would be false.

    A directory the lock names by an absolute path, or by one leaving the
    lock's repository, has no such name, so the package has no source: a copy
    stating none is one package with no other copy. rules_dart's `pub` refuses
    to build such a package; build it from a directory inside the lock's
    repository, or map it with `resolve`.

    Args:
        lock: The lock's `Label`.
        path: The lock entry's `description.path`, relative to the lock's
            directory.

    Returns:
        The source (`pub_hosted_source`), or None.
    """
    unix = path.replace("\\", "/")
    if unix.startswith("/") or (len(unix) > 1 and unix[1] == ":"):
        return None
    directory = lock_path_in_repo(lock, path)
    if directory == ".." or directory.startswith("../"):
        return None
    return struct(identity = directory_identity(lock.repo_name, directory), purl = "")

# The rule declaring a package fetched as each kind of identity.
_FETCHED_RULES = {
    "purl": "fetched_package_metadata",
    "local_git": "fetched_local_git_package_metadata",
    "directory": "fetched_path_package_metadata",
}

def _identity_of(source):
    return source.identity if source != None else None

def _declaration_rule(identity):
    return _FETCHED_RULES[identity.kind] if identity != None else "dart_package_metadata"

def _declaration_load(identity):
    if identity == None:
        return 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\n'
    return 'load("@rules_dart//dart/private:fetched_package_metadata.bzl", "{}")\n'.format(_declaration_rule(identity))

def pub_package_identity(source = None):
    """What a pub package's repository writes to say what it holds.

    Every generated package's BUILD file declares it with the rule `loads`
    loads, which `make_package_metadata_content(source = ...)` writes: one for
    each kind of fetched identity, and `dart_package_metadata` for a package
    without one. A package with a purl also says so to Bazel's supply-chain
    metadata: a `package_metadata` target with the purl, in the BUILD file at
    the repository's root, and a `REPO.bazel` attaching it to every target in
    the repository.
    `make_dart_library_build_content(source = ...)` and
    `make_pub_member_build_content(source = ...)` write the BUILD file's part;
    a rule set writing its own BUILD file puts `loads` among its loads and
    `target` among its targets, and writes `repo_file`, when not empty, as
    `REPO.bazel`.

    Args:
        source: The package's source (`pub_hosted_source`, `pub_git_source`,
            `pub_path_source`), or None for a package no fetcher states.

    Returns:
        `struct(loads, target, repo_file)`; `target` and `repo_file` are ""
        without a purl.
    """
    declaration = _declaration_load(_identity_of(source))
    if source == None or not source.purl:
        return struct(loads = declaration, target = "", repo_file = "")
    return struct(
        loads = 'load("{}", "package_metadata")\n'.format(str(Label("@package_metadata//rules:package_metadata.bzl"))) + declaration,
        target = """
package_metadata(
    name = "{target}",
    purl = "{purl}",
    visibility = ["//visibility:public"],
)
""".format(target = _IDENTITY_TARGET, purl = source.purl),
        repo_file = 'repo(default_package_metadata = ["//:{}"])\n'.format(_IDENTITY_TARGET),
    )

def _identity_attrs(identity):
    if identity == None:
        return ""
    if identity.kind == "purl":
        attrs = [("purl", identity.purl)]
    elif identity.kind == "directory":
        attrs = [("repository", identity.repository), ("directory", identity.directory)]
    else:
        attrs = [
            ("repository", identity.repository),
            ("directory", identity.directory),
            ("commit", identity.commit),
            ("package_path", identity.package_path),
        ]

    # Written even when empty: the main repository's name and a root's path are.
    return "".join(['    {} = "{}",\n'.format(attr, value) for attr, value in attrs])

def make_package_metadata_content(name, language_version, version = "", code_assets = [], build_hook = "", link_hook = "", license_file = "", source = None, visibility = "//visibility:public"):
    """The target declaring a generated package's facts, named `pubspec-metadata`.

    With a source that has a fetched identity, the package is one a fetcher
    fetched, declared by the rule for that kind of identity, which a BUILD file
    of the workspace does not write. Two packages of one name at different
    roots are one package only when both are declared so, with one identity,
    as when rules_dart's `pub` and another rule set's fetcher each fetch it
    from agreeing locks, or each build it from one directory. Without one, a
    `dart_package_metadata`, as for a package of the workspace's own.

    For a rule set whose fetcher writes its own BUILD files (rules_flutter's
    `flutter_pub_package`): put `pub_package_identity(source).loads` among its
    loads, and this among its targets. A copy of a package fetched without an
    identity is not taken for rules_dart's copy of it, so a program reaching
    both fails.

    Args:
        name: The package name.
        language_version: From its `environment.sdk`, or "".
        version: The version pub resolved, or "".
        code_assets: `dart_code_asset` label strings replacing its build hook.
        build_hook: Its unreplaced `hook/build.dart`, package-relative, or "".
        link_hook: Its `hook/link.dart`, package-relative, or "".
        license_file: Its license file (`find_pub_license_file()`), or "".
        source: Where it came from (`pub_hosted_source`, `pub_git_source`,
            `pub_path_source`), or None.
        visibility: The target's visibility.

    Returns:
        BUILD content: the target, without its load.
    """
    return """\
{kind}(
    name = "{target}",
    package_name = "{name}",
    language_version = "{language_version}",
{version}{assets}{hook}{license}{link_hook}{identity}    visibility = ["{visibility}"],
)
""".format(
        kind = _declaration_rule(_identity_of(source)),
        target = _METADATA_TARGET,
        name = name,
        language_version = language_version,
        identity = _identity_attrs(_identity_of(source)),
        visibility = visibility,
        version = _string_block("version", version),
        assets = _list_block("code_assets", code_assets),
        hook = _string_block("build_hook", build_hook),
        license = _string_block("license_file", license_file),
        link_hook = _string_block("link_hook", link_hook),
    )

_TEST_LIBRARY = "test_library"

_TEST_RUNNER_LOAD = """\
load("@rules_dart//dart/pub:pub_library.bzl", "pub_test_runner")
"""

# `package:test`'s spoke also builds the runner `dart_test` runs tests through,
# from this same package, so the two can never be different versions. Built
# once here and shared by every test that depends on `package:test`.
_TEST_RUNNER_BLOCK = """\
pub_test_runner(
    name = "test",
    library = ":{library}",
    visibility = ["//visibility:public"],
)
""".format(library = _TEST_LIBRARY)

def classify_pub_hooks(has_build_hook, has_link_hook, build_hook_handled):
    """Decides what a pub package's hooks mean for its generated `dart_library`.

    A build hook builds native code at `pub get` time, which rules_dart cannot
    run; unless it is replaced by curated `code_assets` or declared irrelevant,
    it is recorded so a consuming binary fails with an explanation. A link hook
    is runnable — a linked program's assets run it — so it is recorded as the
    package's `link_hook` whatever the build hook's fate.

    Args:
        has_build_hook: Whether the package ships `hook/build.dart`.
        has_link_hook: Whether the package ships `hook/link.dart`.
        build_hook_handled: Whether curated `code_assets` replace the build
            hook, or the user listed the package in `ignore_hooks`.

    Returns:
        `struct(unreplaced_hook, link_hook)`: the paths to pass to
        `make_dart_library_build_content`, each empty when not applicable.
    """
    return struct(
        unreplaced_hook = "hook/build.dart" if has_build_hook and not build_hook_handled else "",
        link_hook = "hook/link.dart" if has_link_hook else "",
    )

def choose_pub_license_file(root_files):
    """Picks a pub package's license file from the names of its root's files.

    `flutter build` reports each package under the text of the file `NOTICES`
    at its root if there is one, else `LICENSE`: exact names, compared by
    case. Pure, so the choice is tested apart from a disk.

    Args:
        root_files: Names of the regular files at the package root.

    Returns:
        `NOTICES`, `LICENSE`, or "" when it has neither.
    """
    for name in ("NOTICES", "LICENSE"):
        if name in root_files:
            return name
    return ""

def find_pub_license_file(rctx):
    """Finds the license file of the pub package at a repository's root.

    Reads the directory listing rather than testing whether `NOTICES` exists:
    on a case-insensitive disk (macOS's, by default) a test for `LICENSE` is
    true of a file named `license`, which `flutter build` would not read.

    Args:
        rctx: The repository context, with the package extracted at its root.

    Returns:
        The file's name, for `license_file`; "" when it has none.
    """
    return choose_pub_license_file([
        p.basename
        for p in rctx.path(".").readdir()
        if not p.is_dir
    ])

def make_dart_library_build_content(name, deps, language_version, code_assets = [], build_hook = "", version = "", link_hook = "", license_file = "", source = None):
    """Generate the BUILD.bazel content for a single `dart_library` spoke.

    The shape — a `dart_package_metadata` stating the package's facts, and a
    `dart_library` naming it with `srcs = glob(["lib/**/*.dart"], allow_empty = True)`,
    the non-Dart remainder of `lib/` as `resources`, public visibility and an
    optional deps block — is the canonical pub-spoke layout. Resource-only and Swift-only/Kotlin-only Flutter platform
    packages produce empty source globs but must still resolve as labels, hence
    `allow_empty`.

    The two globs partition `lib/` rather than covering only the Dart half of
    it. A published package's `lib/` is addressable as `package:<name>/<path>`
    whatever the extension, so a spoke that keeps only `*.dart` is a package
    with pieces missing — `dwds` without the client JavaScript it serves,
    `lints` without the YAML every `analysis_options.yaml` includes. Whatever
    a future package ships lands in one of the two globs, so nothing is
    dropped for being unanticipated.

    Args:
        name: The package's name, also the library's target name.
        deps: List of fully-qualified Bazel label strings for sibling spokes
            (e.g. `"@hub__dep//:dep"`). Pass an empty list for no deps.
        language_version: Dart language version string (e.g. `"3.0"`),
            usually the `language_version` that `read_pubspec` returns.
        code_assets: List of `dart_code_asset` label strings replacing this
            package's `hook/build.dart` output. Attaching them here rather
            than at the consuming binary is what makes them propagate: they
            become part of the package's own metadata.
        build_hook: Package-relative path of the package's build hook
            (`hook/build.dart`) when it must be accounted for, or empty when
            it has none or it is declared irrelevant. Without `code_assets`
            replacing it, a consuming binary fails with an explanation
            instead of at runtime.
        version: The resolved package version this spoke was fetched at, or
            empty.
        link_hook: Package-relative path of the package's link hook
            (`hook/link.dart`), or empty.
        license_file: Package-relative path of the package's license file
            (`find_pub_license_file()`), or empty.
        source: Where the package came from
            (`make_package_metadata_content`); its purl is also stated on a
            `package_metadata` target, which the repository's `REPO.bazel`
            (`pub_package_identity(source).repo_file`) attaches to every
            target. None for a package no fetcher states. A spoke that omits
            it is not taken for another fetcher's copy of the package: a
            program reaching both fails, as for two packages sharing a name.

    Returns:
        BUILD.bazel content as a string.
    """
    identity = pub_package_identity(source)
    library = make_package_metadata_content(
        name,
        language_version,
        version = version,
        code_assets = code_assets,
        build_hook = build_hook,
        link_hook = link_hook,
        license_file = license_file,
        source = source,
    ) + identity.target + """
dart_library(
    name = "{target}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{deps}    package = ":{metadata}",
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    runtime_independent = True,
    visibility = ["{visibility}"],
)
""".format(
        # `package:test` keeps its public name for the target that carries the
        # runner beside it; see `_TEST_RUNNER_BLOCK`.
        target = _TEST_LIBRARY if name == "test" else name,
        deps = _list_block("deps", deps),
        metadata = _METADATA_TARGET,
        visibility = "//visibility:private" if name == "test" else "//visibility:public",
    )
    loads = 'load("@rules_dart//dart:defs.bzl", "dart_library")\n' + identity.loads
    if name != "test":
        return loads + "\n" + library
    return loads + _TEST_RUNNER_LOAD + "\n" + library + "\n" + _TEST_RUNNER_BLOCK

_PUB_LIBRARY_LOAD = 'load("@rules_dart//dart/pub:pub_library.bzl", "{rule}")\n'

def _list_block(attr, items):
    if not items:
        return ""
    return "    {} = [\n{}\n    ],\n".format(attr, "\n".join(['        "{}",'.format(i) for i in items]))

def _string_block(attr, value):
    return '    {} = "{}",\n'.format(attr, value) if value else ""

def make_pub_member_build_content(name, language_version, version, code_assets = [], unreplaced_hook = "", link_hook = "", license_file = "", source = None):
    """The BUILD file of a `pub.from_lock()` package's source repository.

    It states what the package's own archive says — its files, language
    version, hooks — and nothing about other packages: which packages it is
    built with is its library repository's to decide
    (`make_pub_library_build_content`). The two globs partition `lib/`, as
    `make_dart_library_build_content`'s do.

    Args:
        name: The package name, also the target's.
        language_version: From the package's `environment.sdk`.
        version: The version pub resolved.
        code_assets: `dart_code_asset` labels replacing its build hook.
        unreplaced_hook: Its unreplaced build hook's path, or "".
        link_hook: `hook/link.dart` if it has one, or "".
        license_file: Its license file (`find_pub_license_file()`), or "".
        source: Where it came from, as for
            `make_dart_library_build_content`, or None.

    Returns:
        BUILD.bazel content.
    """
    identity = pub_package_identity(source)
    return _PUB_LIBRARY_LOAD.format(rule = "pub_package_member") + identity.loads + "\n" + make_package_metadata_content(
        name,
        language_version,
        version = version,
        code_assets = code_assets,
        build_hook = unreplaced_hook,
        link_hook = link_hook,
        license_file = license_file,
        source = source,
    ) + identity.target + """
pub_package_member(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    package = ":{metadata}",
    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        metadata = _METADATA_TARGET,
    )

def make_pub_library_build_content(name, members = [], deps = [], owner = ""):
    """The BUILD file of a `pub.from_lock()` package's library repository.

    The package's dependency cycle (pub allows one; Bazel does not) is built as
    one `pub_library` in the library repository of its first package, by name;
    every other package of the cycle aliases it. A package in no cycle is a
    cycle of one. `package:test`'s also builds the runner `dart_test` uses, as
    `make_dart_library_build_content` does.

    Args:
        name: The package name.
        members: For the cycle's first package, the labels of every member's
            `pub_package_member`; otherwise empty.
        deps: For the cycle's first package, the labels of the libraries the
            cycle depends on; otherwise empty.
        owner: For any other package of the cycle, the label of the library
            the first one builds; otherwise empty.

    Returns:
        BUILD.bazel content.
    """
    target = _TEST_LIBRARY if name == "test" else name
    visibility = "//visibility:private" if name == "test" else "//visibility:public"
    if owner:
        library = """
alias(
    name = "{target}",
    actual = "{owner}",
    visibility = ["{visibility}"],
)
""".format(target = target, owner = owner, visibility = visibility)
        content = ""
    else:
        library = """
pub_library(
    name = "{target}",
{members}{deps}    visibility = ["{visibility}"],
)
""".format(
            target = target,
            members = _list_block("members", members),
            deps = _list_block("deps", deps),
            visibility = visibility,
        )
        content = _PUB_LIBRARY_LOAD.format(rule = "pub_library")
    if name != "test":
        return content + library
    return content + _TEST_RUNNER_LOAD + library + "\n" + _TEST_RUNNER_BLOCK
