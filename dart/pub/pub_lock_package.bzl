"""Repository rules that fetch a single pub package: a locked one, or a `pub.package()`.

Each hosted, git or built-from-pubspec path package gets its own source
repository (spoke), holding its files and the facts it states about itself as
a `pub_package_member`: `pub_lock_package` for a hosted or git package,
`pub_lock_path_package` for a path one. A hosted or git package's files are
fetched into a repository of their own (`pub_archive_files`, `pub_git_files`)
and linked in with `link_pub_files`, so Bazel's repository cache keeps one
copy of each package version however often the generated build changes. The
files repository records what it fetched, from which the source repository
states the package's name, version and source (`pub_files_fetched`).
Which packages it is built with — its dependency cycle, if pub resolved one —
is decided by its library repository (`pub_lock_library`), which the hub's
`@hub//:pkg` aliases point at. A `path` package `resolve` maps to a target of
the user's gets `pub_lock_resolved_pubspec` instead, which holds only the
dependencies its pubspec states, so that planning finds a cycle through it.

Also re-exports public Starlark helpers for other Bazel rule sets (notably
rules_flutter's `flutter_pub_package`, the `flutter pub get` analog):
`pub_archive_files` and `pub_git_files` fetch a hosted or git package into a
repository of its own, which `link_pub_files` (naming it by `pub_files_label`)
links into a repository that builds it, and `pub_files_fetched` reads what
it fetched;
`fetch_pub_archive` (with `check_pub_archive_sha256`) fetches a hosted package
`fetch_pub_git` (with `check_pub_git_resolved_ref`) a git package and
`link_pub_path` serves a path package's directory exactly as rules_dart's own
pub rules do, `is_relative_git_url` says whether a lock's
git `url` is relative to the lock (only then does the package depend on it),
`find_pub_license_file` finds a package's
license file as `flutter build` does, and `make_dart_library_build_content` emits the
same `dart_package_metadata` and `dart_library` shape for non-plugin packages.
`pub_hosted_purl` and `pub_git_purl` give a fetched package's purl, which
an SBOM lists. `pub_hosted_source`, `pub_git_source` and `pub_path_source` give
a package's source: what it was fetched as, its fetched identity, and its purl
if it has one, which `make_package_metadata_content` and the other generators
take whole. `pub_package_identity` gives the loads a source's declaration needs
and, for a purl, the `package_metadata` target and `REPO.bazel` that state it
for the whole repository, as Bazel's supply-chain metadata expects of a
repository fetched from a registry.

A second pub extension refuses the locks `pub.from_lock` refuses with the same
three functions. `pub_lock_mapping_error` checks how a tag maps one lock's
packages; `pub_lock_entry` reads a package of a lock; and, once every lock is
read, `pub_lock_disagreement_errors` compares the entries a package has across
them. `pub_lock_path_directory` finds a `path` package's directory from the
lock and the entry's `path`, as `pub_lock_path_package` does.
"""

load("//dart/pub:pub_graph.bzl", "PUBSPEC_DEPENDENCIES", "write_pubspec_dependencies")
load("//dart/pub:pubspec.bzl", "read_pubspec")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _find_pub_license_file = "find_pub_license_file", _make_dart_library_build_content = "make_dart_library_build_content", _make_package_metadata_content = "make_package_metadata_content", _make_pub_member_build_content = "make_pub_member_build_content", _normalize_pub_path = "normalize_pub_path", _pub_git_purl = "pub_git_purl", _pub_git_source = "pub_git_source", _pub_hosted_purl = "pub_hosted_purl", _pub_hosted_source = "pub_hosted_source", _pub_package_identity = "pub_package_identity", _pub_path_source = "pub_path_source")
load("//dart/pub/private:pub_archive.bzl", _check_pub_archive_sha256 = "check_pub_archive_sha256", _fetch_pub_archive = "fetch_pub_archive")
load("//dart/pub/private:pub_files.bzl", "FILES_LOAD", _pub_archive_files = "pub_archive_files", _pub_files_label = "pub_files_label", _pub_git_files = "pub_git_files")
load("//dart/pub/private:pub_files_names.bzl", "read_files_load")
load("//dart/pub/private:pub_git.bzl", _check_pub_git_resolved_ref = "check_pub_git_resolved_ref", _fetch_pub_git = "fetch_pub_git", _is_relative_git_url = "is_relative_git_url")
load("//dart/pub/private:pub_lock_checks.bzl", _pub_lock_disagreement_errors = "pub_lock_disagreement_errors", _pub_lock_entry = "pub_lock_entry", _pub_lock_mapping_error = "pub_lock_mapping_error", _published_by_rules_dart = "published_by_rules_dart")
load("//dart/pub/private:pub_path.bzl", _link_pub_path = "link_pub_path")
load("//dart/pub/private:pub_refusal.bzl", "PUBSPEC_REFUSAL", "failing_target", "write_pubspec_refusal")

# Re-export for consumers outside //dart/pub (rules_flutter's
# flutter_pub_package). Loading the private bzl directly would trip
# buildifier's bzl-visibility check, so we expose it via this public file.
published_by_rules_dart = _published_by_rules_dart
pub_lock_mapping_error = _pub_lock_mapping_error
pub_lock_entry = _pub_lock_entry
pub_lock_disagreement_errors = _pub_lock_disagreement_errors
make_dart_library_build_content = _make_dart_library_build_content
make_package_metadata_content = _make_package_metadata_content
find_pub_license_file = _find_pub_license_file
pub_hosted_purl = _pub_hosted_purl
pub_git_purl = _pub_git_purl
pub_hosted_source = _pub_hosted_source
pub_git_source = _pub_git_source
pub_path_source = _pub_path_source
pub_package_identity = _pub_package_identity
fetch_pub_archive = _fetch_pub_archive
check_pub_archive_sha256 = _check_pub_archive_sha256
fetch_pub_git = _fetch_pub_git
check_pub_git_resolved_ref = _check_pub_git_resolved_ref
is_relative_git_url = _is_relative_git_url
link_pub_path = _link_pub_path
pub_archive_files = _pub_archive_files
pub_git_files = _pub_git_files
pub_files_label = _pub_files_label

# Names a source repository owns at its root: Bazel's own files, which
# would make the root another package or repository, and what the source
# repository writes, which must never write through a link into the files.
_NEVER_LINKED = ["BUILD", "BUILD.bazel", "MODULE.bazel", "REPO.bazel", "WORKSPACE", "WORKSPACE.bazel", "WORKSPACE.bzlmod", FILES_LOAD]

def link_pub_files(rctx, files, written = []):
    """Links a files repository's package into a source repository's root.

    Each entry at the package's root is linked at its own name, except Bazel's
    files and the names in `written`, so the source repository can write its
    own at its root. Write only at the root, and only names in `written`:
    writing below it would write through a link into the files, which other
    repositories share.

    The links name a path in this output base, so a repository calling this
    must not mark itself reproducible: a cached copy would link into another.
    `bazel vendor` rewrites them to name whichever output base builds, and
    the source repository's BUILD file must begin with the load this returns,
    so that Bazel makes the files repository there before reading through
    the links: a vendored source repository is never fetched again.

    Args:
        rctx: The source repository's `repository_ctx`.
        files: The files repository's label, as `pub_files_label` gives it.
        written: Root names the caller writes, which are not linked.

    Returns:
        The load statement the source repository's BUILD file begins with.
    """
    root = rctx.path(files).dirname
    skip = _NEVER_LINKED + written

    # Unwatched: the files repository changes only with its attributes, and
    # `rctx.path(files)` already makes this repository depend on it.
    for child in root.readdir(watch = "no"):
        if child.basename not in skip:
            rctx.symlink(child, child.basename)
    return 'load("{}", "FILES")\n'.format(files.same_package_label(FILES_LOAD))

def pub_files_fetched(rctx, files):
    """What a files repository fetched, and so what the package it holds is.

    `pub_archive_files` and `pub_git_files` record what they fetched. A source
    repository states the package's name, version and source from
    that record, never from attributes of its own, which could describe bytes
    its files repository never fetched.

    Args:
        rctx: The source repository's `repository_ctx`.
        files: The files repository's label, as `pub_files_label` gives it.

    Returns:
        `struct(package_name, version, source)`: the package's source
        (`pub_hosted_source`, `pub_git_source`). None for files whose
        repository records nothing (`write_pub_files_root` without `fetched`).
    """

    # Unwatched: the record changes only with the files repository, which
    # `rctx.path(files)` already makes this repository depend on.
    record = read_files_load(rctx.read(rctx.path(files).dirname.get_child(FILES_LOAD), watch = "no"))
    if record == None:
        return None
    name = record["package_name"]
    version = record["version"]
    if record["source"] == "hosted":
        return struct(
            package_name = name,
            version = version,
            source = _pub_hosted_source(name, version, record["sha256"], record["base_url"]),
        )
    return struct(
        package_name = name,
        version = version,
        source = _pub_git_source(
            name,
            version,
            record["url"],
            record["resolved_ref"],
            record["path"],
            Label(record["lock"]) if record["lock"] else None,
        ),
    )

# What a Dart package's build reads from its directory.
_PATH_PACKAGE_ENTRIES = ["pubspec.yaml", "lib", "hook", "LICENSE", "NOTICES"]

# A member is never reproducible: its links name this output base (hosted and
# git), or its files are the user's, outside Bazel's control (path).
def _write_member(ctx, package_name, version, source, build_prelude = "", refusal = None):
    # Read the package's SDK constraint, to mirror pub's per-package
    # languageVersion behaviour, and its dependencies, which it records for
    # its library repository and the library repositories of packages that
    # reach it: parsed once here, not by each.
    language_version = ""
    pubspec_deps = []
    if not refusal and ctx.path("pubspec.yaml").exists:
        read = read_pubspec(ctx, package_name, version)
        refusal = read.error
        if not refusal:
            language_version = read.pubspec.language_version
            pubspec_deps = read.pubspec.dependencies
    write_pubspec_dependencies(ctx, pubspec_deps)
    write_pubspec_refusal(ctx, refusal)
    if refusal:
        # The whole lock is materialised, packages no build uses included.
        ctx.file("BUILD.bazel", build_prelude + failing_target(package_name, refusal))
        return ctx.repo_metadata(reproducible = False)

    # A package that builds native code declares a build hook. rules_dart
    # cannot run it, so unless a curated `dart_code_asset` replaces it — or the
    # user has declared it irrelevant — record it for the consuming binary to
    # complain about. Recording rather than failing here is deliberate: the
    # whole lock is materialised, including packages nothing depends on. A link
    # hook is recorded too, for a linked program to run.
    hooks = _classify_pub_hooks(
        has_build_hook = ctx.path("hook/build.dart").exists,
        has_link_hook = ctx.path("hook/link.dart").exists,
        build_hook_handled = bool(ctx.attr.code_assets) or ctx.attr.ignore_hook,
    )

    ctx.file("BUILD.bazel", build_prelude + _make_pub_member_build_content(
        name = package_name,
        language_version = language_version,
        code_assets = ctx.attr.code_assets,
        unreplaced_hook = hooks.unreplaced_hook,
        version = version,
        link_hook = hooks.link_hook,
        license_file = _find_pub_license_file(ctx),
        source = source,
    ))

    # What the package is and where it came from, for every target in the
    # repository. A path package's files are its repository's own, which
    # states their origin.
    repo_file = _pub_package_identity(source).repo_file
    if repo_file:
        ctx.file("REPO.bazel", repo_file)
    return ctx.repo_metadata(reproducible = False)

def _pub_lock_package_impl(ctx):
    # Its files are another repository's, linked in: see `link_pub_files`.
    build_prelude = link_pub_files(ctx, ctx.attr.files, written = [PUBSPEC_DEPENDENCIES, PUBSPEC_REFUSAL])
    fetched = pub_files_fetched(ctx, ctx.attr.files)
    if fetched == None:
        fail("@{}: its files repository {} records nothing it fetched: name one `pub_archive_files` or `pub_git_files` makes.".format(ctx.original_name, ctx.attr.files))
    return _write_member(
        ctx,
        fetched.package_name,
        fetched.version,
        fetched.source,
        build_prelude = build_prelude,
    )

def pub_lock_path_directory(rctx, lock, path):
    """The directory of a `path` package, from the lock that lists it.

    As pub does, the path is resolved lexically against the lock's directory,
    with `/` or `\\` between its parts. `pub_lock_entry` gives both arguments,
    for a directory inside the lock's repository.

    Args:
        rctx: The `repository_ctx`.
        lock: The lock's `Label`.
        path: The entry's `description.path`, relative to the lock's directory.

    Returns:
        The directory's `path`.
    """
    directory = rctx.path(lock).dirname
    for part in _normalize_pub_path(path).split("/"):
        if part == "..":
            directory = directory.dirname
        elif part:
            directory = directory.get_child(part)
    return directory

def _pub_lock_path_package_impl(ctx):
    source = _pub_path_source(ctx.attr.lock, ctx.attr.path)
    if source == None:
        # `pub.from_lock()` refuses such a path when it reads the lock.
        fail(("@{}: package `{}` is at `{}` from {}, outside the repository " +
              "that holds the lock, so nothing identifies the directory it is " +
              "built from. A repository builds only its own files; move the " +
              "package into it, or map it with `resolve` to a target that builds it.").format(
            ctx.original_name,
            ctx.attr.package_name,
            ctx.attr.path,
            ctx.attr.lock,
        ))
    directory = pub_lock_path_directory(ctx, ctx.attr.lock, ctx.attr.path)
    problem = link_pub_path(ctx, directory, _PATH_PACKAGE_ENTRIES)
    if not problem and not ctx.path("pubspec.yaml").exists:
        # A directory an uninitialized submodule left, say: nothing to build from.
        problem = ("%s has no pubspec.yaml. The lock lists the package by path; check it " +
                   "out there, or name it in `resolve` or `ignored` instead.") % directory
    refusal = None
    if problem:
        refusal = "Pub package \"%s\" %s cannot be built: %s" % (ctx.attr.package_name, ctx.attr.version, problem)
    return _write_member(ctx, ctx.attr.package_name, ctx.attr.version, source, refusal = refusal)

_MEMBER_ATTRS = {
    "ignore_hook": attr.bool(
        doc = "Suppress the unreplaced-hook diagnostic for this package. Set by " +
              "`pub.from_lock(ignore_hooks = [...])` or " +
              "`pub.package(ignore_hook = True)`; never a default.",
        default = False,
    ),
    "code_assets": attr.string_list(
        doc = "Labels of `dart_code_asset` targets replacing this package's " +
              "`hook/build.dart` output. Resolved by the `pub` extension from " +
              "rules_dart's curated registry; stated on the generated " +
              "`dart_package_metadata` so they propagate to every consumer.",
        default = [],
    ),
}

pub_lock_package = repository_rule(
    implementation = _pub_lock_package_impl,
    attrs = _MEMBER_ATTRS | {
        "files": attr.label(
            doc = "The package's files repository, as `pub_files_label` names it: " +
                  "`pub_archive_files` or `pub_git_files`, whose record of what it " +
                  "fetched gives the package's name, version and source.",
            mandatory = True,
        ),
    },
    doc = "Generates the build of a single hosted or git package, from a pubspec.lock or a " +
          "`pub.package()`, over the files `pub_archive_files` or `pub_git_files` fetched.",
)

pub_lock_path_package = repository_rule(
    implementation = _pub_lock_path_package_impl,
    attrs = _MEMBER_ATTRS | {
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version, as pubspec.lock records it.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The lock, against whose directory `path` is resolved.",
            allow_single_file = True,
            mandatory = True,
        ),
        "path": attr.string(
            doc = "The package's directory relative to the lock's: the lock's " +
                  "`description.path`, `/`-separated. It stays inside the lock's repository.",
            mandatory = True,
        ),
    },
    doc = "Serves a `source: path` package from its directory, built from its pubspec, and generates a BUILD file.",
)

def _pub_lock_resolved_pubspec_impl(ctx):
    pubspec = pub_lock_path_directory(ctx, ctx.attr.lock, ctx.attr.path).get_child("pubspec.yaml")
    ctx.watch(pubspec)
    if pubspec.exists and not pubspec.is_dir:
        ctx.symlink(pubspec, "pubspec.yaml")
        read = read_pubspec(ctx, ctx.attr.package_name, ctx.attr.version)
        dependencies = read.pubspec.dependencies if read.pubspec else []
        refusal = read.error
    else:
        # Only a pub package reaching this one needs its pubspec, to plan with.
        dependencies = []
        refusal = ("pub.from_lock(): %s lists package `%s` at `%s`, and %s does not exist. " +
                   "Check out the package there, or run `dart pub get` so the lock says where " +
                   "it is.") % (ctx.attr.lock, ctx.attr.package_name, ctx.attr.path, pubspec)
    write_pubspec_dependencies(ctx, dependencies)
    write_pubspec_refusal(ctx, refusal)
    ctx.file("BUILD.bazel", "")

    # Its pubspec is the user's, outside Bazel's control.
    return ctx.repo_metadata(reproducible = False)

pub_lock_resolved_pubspec = repository_rule(
    implementation = _pub_lock_resolved_pubspec_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The pub package name."),
        "version": attr.string(doc = "The package version, as pubspec.lock records it, for messages."),
        "lock": attr.label(
            doc = "The lock, against whose directory `path` is resolved.",
            allow_single_file = True,
            mandatory = True,
        ),
        "path": attr.string(
            doc = "The package's directory relative to the lock's: the lock's " +
                  "`description.path`, `/`-separated. It stays inside the lock's repository.",
            mandatory = True,
        ),
    },
    doc = "Records the pubspec dependencies of a `path` package `resolve` maps to a target of " +
          "the user's, so the library repositories of pub packages can find a cycle through it.",
)
