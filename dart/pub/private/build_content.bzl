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

visibility("//dart/...")

# The `package_metadata` target a fetched package's repository attaches to
# every target in it. Not a Dart package name, so no library can be called it.
_IDENTITY_TARGET = "package-metadata"

# The `dart_package_metadata` of a fetched package, which its library names.
# The library is called after the package, and this is not a Dart package
# name, so the two never collide.
_METADATA_TARGET = "pubspec-metadata"

# pub.dev, by its names in locks: what a purl of type `pub` means when it
# names no `repository_url` (the purl spec's default is the older name).
_PUB_DEV = ["https://pub.dev", "https://pub.dartlang.org"]

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
    registry = base_url.rstrip("/")
    if registry not in _PUB_DEV:
        builder.add_qualifier("repository_url", registry)
    return builder.build()

def pub_git_purl(name, version, url, resolved_ref, path = "."):
    """The purl of a git pub package at its locked commit.

    `pkg:pub/<name>@<version>?vcs_url=git+<url>@<commit>`, with `#<path>`
    for a package in a subdirectory, as an SPDX VCS location writes it. The
    url is the lock's, as written, relative ones too, so the purl names what
    the lock names on every machine.

    Args:
        name: The pub package name.
        version: The package version.
        url: The lock entry's `description.url`.
        resolved_ref: The locked commit: `description.resolved-ref`.
        path: The lock entry's `description.path`.

    Returns:
        The purl, as the `package_metadata` module's builder writes it.
    """
    location = "git+{}@{}".format(url, resolved_ref)
    if path != ".":
        location += "#" + path
    return purl.builder().type("pub").name(name).version(version).add_qualifier("vcs_url", location).build()

def pub_package_identity(purl):
    """What a fetched pub package's repository writes to say what it holds.

    A `package_metadata` target with the package's purl, in the BUILD file at
    the repository's root, and a `REPO.bazel` attaching it to every target in
    the repository, as Bazel's supply-chain metadata expects of a repository
    fetched from a registry. `make_dart_library_build_content(purl = ...)`
    and `make_pub_member_build_content(purl = ...)` write the first two; a
    rule set writing its own BUILD file puts `loads` among its loads and
    `target` among its targets, and writes `repo_file` as `REPO.bazel`.

    Args:
        purl: The package's purl (`pub_hosted_purl`, `pub_git_purl`), or ""
            for a package of the user's own (a path package), which states
            its own.

    Returns:
        `struct(loads, target, repo_file)`, each "" for no purl.
    """
    if not purl:
        return struct(loads = "", target = "", repo_file = "")
    return struct(
        loads = 'load("{}", "package_metadata")\n'.format(str(Label("@package_metadata//rules:package_metadata.bzl"))),
        target = """
package_metadata(
    name = "{target}",
    purl = "{purl}",
    visibility = ["//visibility:public"],
)
""".format(target = _IDENTITY_TARGET, purl = purl),
        repo_file = 'repo(default_package_metadata = ["//:{}"])\n'.format(_IDENTITY_TARGET),
    )

_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_library", "dart_package_metadata")\n'

def _metadata_block(name, language_version, version = "", code_assets = [], build_hook = "", link_hook = "", license_file = ""):
    return """\
dart_package_metadata(
    name = "{target}",
    package_name = "{name}",
    language_version = "{language_version}",
{version}{assets}{hook}{license}{link_hook}    visibility = ["//visibility:public"],
)
""".format(
        target = _METADATA_TARGET,
        name = name,
        language_version = language_version,
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

def make_dart_library_build_content(name, deps, language_version, code_assets = [], build_hook = "", version = "", link_hook = "", license_file = "", purl = ""):
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
            empty. A trailing keyword with a default because this helper is
            re-exported for rule sets outside //dart/pub — notably
            rules_flutter's `flutter_pub_package` — whose existing calls must
            keep working; a spoke that omits it simply states no version, and
            an unstated version never conflicts with a stated one.
        link_hook: Package-relative path of the package's link hook
            (`hook/link.dart`), or empty. Trailing with a default for the same
            reason as `version`.
        license_file: Package-relative path of the package's license file
            (`find_pub_license_file()`), or empty. Trailing with a default for
            the same reason as `version`.
        purl: The package's purl (`pub_hosted_purl`, `pub_git_purl`), for a
            `package_metadata` target, which the repository's `REPO.bazel`
            (`pub_package_identity(purl).repo_file`) attaches to every
            target; empty for a package of the user's own, which states none.

    Returns:
        BUILD.bazel content as a string.
    """
    library = _metadata_block(
        name,
        language_version,
        version = version,
        code_assets = code_assets,
        build_hook = build_hook,
        link_hook = link_hook,
        license_file = license_file,
    ) + pub_package_identity(purl).target + """
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
    loads = _LOAD + pub_package_identity(purl).loads
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

def make_pub_member_build_content(name, language_version, version, code_assets = [], unreplaced_hook = "", link_hook = "", license_file = "", purl = ""):
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
        purl: Its purl, as for `make_dart_library_build_content`, or "".

    Returns:
        BUILD.bazel content.
    """
    return 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\n' + _PUB_LIBRARY_LOAD.format(rule = "pub_package_member") + pub_package_identity(purl).loads + "\n" + _metadata_block(
        name,
        language_version,
        version = version,
        code_assets = code_assets,
        build_hook = unreplaced_hook,
        link_hook = link_hook,
        license_file = license_file,
    ) + pub_package_identity(purl).target + """
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
