"""Repository rules that fetch a single pub package: a locked one, or a `pub.package()`.

Each hosted, git or built-from-pubspec path package gets its own source
repository (spoke), holding its files and the facts it states about itself as
a `pub_package_member`: `pub_lock_package` for a hosted package,
`pub_lock_git_package` for a git one, `pub_lock_path_package` for a path one.
A hosted or git package's files are fetched into a repository of their own
(`pub_archive_files`, `pub_git_files`) and linked in with `link_pub_files`, so
Bazel's repository cache keeps one copy of each package version however often
the generated build changes.
Which packages it is built with — its dependency cycle, if pub resolved one —
is decided by its library repository (`pub_lock_library`), which the hub's
`@hub//:pkg` aliases point at. A `path` package `resolve` maps to a target of
the user's gets `pub_lock_resolved_pubspec` instead, which holds only the
dependencies its pubspec states, so that planning finds a cycle through it.

Also re-exports public Starlark helpers for other Bazel rule sets (notably
rules_flutter's `flutter_pub_package`, the `flutter pub get` analog):
`pub_archive_files` and `pub_git_files` fetch a hosted or git package into a
repository of its own, which `link_pub_files` (naming it by `pub_files_label`)
links into a repository that builds it;
`fetch_pub_archive` (with `check_pub_archive_sha256`) fetches a hosted package
`fetch_pub_git` (with `check_pub_git_resolved_ref`) a git package and
`fetch_pub_path` a path package's directory exactly as rules_dart's own pub
rules do, `is_relative_git_url` says whether a lock's
git `url` is relative to the lock (only then does the package depend on it),
`find_pub_license_file` finds a package's
license file as `flutter build` does, and `make_dart_library_build_content` emits the
same `dart_package_metadata` and `dart_library` shape for non-plugin packages.
`pub_hosted_purl` and `pub_git_purl` give a fetched package's purl, and
`pub_package_identity` the `package_metadata` target and `REPO.bazel` that
state it for the whole repository, as Bazel's supply-chain metadata expects of
a repository fetched from a registry.
"""

load("//dart/pub:pub_graph.bzl", "PUBSPEC_DEPENDENCIES", "write_pubspec_dependencies")
load("//dart/pub:pubspec.bzl", "read_pubspec")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _find_pub_license_file = "find_pub_license_file", _make_dart_library_build_content = "make_dart_library_build_content", _make_pub_member_build_content = "make_pub_member_build_content", _pub_git_purl = "pub_git_purl", _pub_hosted_purl = "pub_hosted_purl", _pub_package_identity = "pub_package_identity")
load("//dart/pub/private:pub_archive.bzl", _check_pub_archive_sha256 = "check_pub_archive_sha256", _fetch_pub_archive = "fetch_pub_archive")
load("//dart/pub/private:pub_files.bzl", "FILES_LOAD", _pub_archive_files = "pub_archive_files", _pub_files_label = "pub_files_label", _pub_git_files = "pub_git_files")
load("//dart/pub/private:pub_git.bzl", _check_pub_git_resolved_ref = "check_pub_git_resolved_ref", _fetch_pub_git = "fetch_pub_git", _is_relative_git_url = "is_relative_git_url")
load("//dart/pub/private:pub_path.bzl", _fetch_pub_path = "fetch_pub_path")

# Re-export for consumers outside //dart/pub (rules_flutter's
# flutter_pub_package). Loading the private bzl directly would trip
# buildifier's bzl-visibility check, so we expose it via this public file.
make_dart_library_build_content = _make_dart_library_build_content
find_pub_license_file = _find_pub_license_file
pub_hosted_purl = _pub_hosted_purl
pub_git_purl = _pub_git_purl
pub_package_identity = _pub_package_identity
fetch_pub_archive = _fetch_pub_archive
check_pub_archive_sha256 = _check_pub_archive_sha256
fetch_pub_git = _fetch_pub_git
check_pub_git_resolved_ref = _check_pub_git_resolved_ref
is_relative_git_url = _is_relative_git_url
fetch_pub_path = _fetch_pub_path
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

# What a Dart package's build reads from its directory.
_PATH_PACKAGE_ENTRIES = ["pubspec.yaml", "lib", "hook", "LICENSE", "NOTICES"]

# A member is never reproducible: its links name this output base (hosted and
# git), or its files are the user's, outside Bazel's control (path).
def _write_member(ctx, purl = "", build_prelude = ""):
    # Read the package's SDK constraint, to mirror pub's per-package
    # languageVersion behaviour, and its dependencies, which it records for
    # its library repository and the library repositories of packages that
    # reach it: parsed once here, not by each.
    language_version = ""
    pubspec_deps = []
    if ctx.path("pubspec.yaml").exists:
        pubspec = read_pubspec(ctx, ctx.attr.package_name, ctx.attr.version)
        language_version = pubspec.language_version
        pubspec_deps = pubspec.dependencies
    write_pubspec_dependencies(ctx, pubspec_deps)

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
        name = ctx.attr.package_name,
        language_version = language_version,
        code_assets = ctx.attr.code_assets,
        unreplaced_hook = hooks.unreplaced_hook,
        version = ctx.attr.version,
        link_hook = hooks.link_hook,
        license_file = _find_pub_license_file(ctx),
        purl = purl,
    ))

    # What the package is and where it came from, for every target in the
    # repository. A path package is the user's own, and states its own.
    if purl:
        ctx.file("REPO.bazel", _pub_package_identity(purl).repo_file)
    return ctx.repo_metadata(reproducible = False)

# Its files are another repository's, linked in: see `link_pub_files`.
def _link_files(ctx):
    return link_pub_files(ctx, ctx.attr.files, written = [PUBSPEC_DEPENDENCIES])

def _pub_lock_package_impl(ctx):
    build_prelude = _link_files(ctx)
    return _write_member(ctx, purl = _pub_hosted_purl(
        ctx.attr.package_name,
        ctx.attr.version,
        ctx.attr.sha256,
        ctx.attr.base_url,
    ), build_prelude = build_prelude)

def _pub_lock_git_package_impl(ctx):
    build_prelude = _link_files(ctx)
    return _write_member(ctx, purl = _pub_git_purl(
        ctx.attr.package_name,
        ctx.attr.version,
        ctx.attr.url,
        ctx.attr.resolved_ref,
        ctx.attr.path,
    ), build_prelude = build_prelude)

def _lock_path_directory(ctx):
    # As pub does, the path is resolved lexically against the lock's directory.
    directory = ctx.path(ctx.attr.lock).dirname
    for part in ctx.attr.path.split("/"):
        if part == "..":
            directory = directory.dirname
        elif part not in ("", "."):
            directory = directory.get_child(part)
    return directory

def _pub_lock_path_package_impl(ctx):
    fetch_pub_path(ctx, _lock_path_directory(ctx), _PATH_PACKAGE_ENTRIES)

    return _write_member(ctx)

_MEMBER_ATTRS = {
    "package_name": attr.string(
        doc = "The pub package name.",
        mandatory = True,
    ),
    "version": attr.string(
        doc = "The package version, as pubspec.lock records it.",
        mandatory = True,
    ),
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

_FILES_ATTR = {
    "files": attr.label(
        doc = "The package's files repository, as `pub_files_label` names it.",
        mandatory = True,
    ),
}

pub_lock_package = repository_rule(
    implementation = _pub_lock_package_impl,
    attrs = _MEMBER_ATTRS | _FILES_ATTR | {
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive, as pubspec.lock records it, for its purl.",
            mandatory = True,
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository, for its purl.",
            default = "https://pub.dev",
        ),
    },
    doc = "Generates the build of a single hosted package, from a pubspec.lock or a `pub.package()`, " +
          "over the files `pub_archive_files` fetched.",
)

pub_lock_git_package = repository_rule(
    implementation = _pub_lock_git_package_impl,
    attrs = _MEMBER_ATTRS | _FILES_ATTR | {
        "url": attr.string(
            doc = "The repository, as pubspec.lock's `description.url` records it.",
            mandatory = True,
        ),
        "resolved_ref": attr.string(
            doc = "The locked commit: `description.resolved-ref`, a full commit id.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "The package's directory in the repository: `description.path`.",
            default = ".",
        ),
    },
    doc = "Generates the build of a single git package from a pubspec.lock, over the files `pub_git_files` fetched.",
)

pub_lock_path_package = repository_rule(
    implementation = _pub_lock_path_package_impl,
    attrs = _MEMBER_ATTRS | {
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
    pubspec = _lock_path_directory(ctx).get_child("pubspec.yaml")
    ctx.watch(pubspec)
    if not pubspec.exists:
        fail(("pub.from_lock(): %s lists package `%s` at `%s`, and %s does not exist. " +
              "Check out the package there, or run `dart pub get` so the lock says where " +
              "it is.") % (ctx.attr.lock, ctx.attr.package_name, ctx.attr.path, pubspec))
    ctx.symlink(pubspec, "pubspec.yaml")
    write_pubspec_dependencies(ctx, read_pubspec(ctx, ctx.attr.package_name, ctx.attr.version).dependencies)
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
