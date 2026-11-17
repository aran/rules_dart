"""The `dart_package_metadata` rule: a Dart package's facts, declared once."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartDataAssetInfo", "DartPackageMetadataInfo")
load("//dart/private:package_info.bzl", "DartLinkedCodeAssetInfo", "check_code_asset_ownership", "check_data_asset_ownership", "check_linked_code_asset_ownership", "data_assets_of", "directory_identity", "link_hook_assets_error", "local_git_identity", "purl_identity")
load("//dart/private:package_root.bzl", "locate_package_root")

visibility("//dart/...")

def link_hook_error(label, package_root, link_hook):
    """Checks that a `link_hook` is the package's `hook/link.dart`.

    The hook's location is how a linked program finds the package root it
    hands the hook, so a file anywhere else would give the hook the wrong
    `packageRoot`.

    Args:
        label: The declaring target's label, for the message.
        package_root: The package root's `short_path`; empty for the root package.
        link_hook: The `link_hook` File, or None.

    Returns:
        An error string, or None.
    """
    if link_hook == None:
        return None
    expected = (package_root + "/" if package_root else "") + "hook/link.dart"
    if link_hook.short_path != expected:
        return ("%s: `link_hook` must be the package's `hook/link.dart` (`%s`), " +
                "got `%s`. The hook's location is the package root it is " +
                "run against.") % (label, expected, link_hook.short_path)
    return None

def build_hook_error(label, package_root, build_hook):
    """Checks that a `build_hook` is the package's `hook/build.dart`.

    Args:
        label: The declaring target's label, for the message.
        package_root: The package root's `short_path`; empty for the root package.
        build_hook: The `build_hook` File, or None.

    Returns:
        An error string, or None.
    """
    if build_hook == None:
        return None
    expected = (package_root + "/" if package_root else "") + "hook/build.dart"
    if build_hook.short_path != expected:
        return ("%s: `build_hook` must be the package's `hook/build.dart` (`%s`), " +
                "got `%s`.") % (label, expected, build_hook.short_path)
    return None

def unreplaced_build_hook(build_hook, assets):
    """The package-relative path of a build hook nothing replaces, or "".

    rules_dart does not run a build hook. The code and data assets the package
    owns replace what it would build, as curated ones replace a pub package's.

    Args:
        build_hook: The `build_hook` File, or None.
        assets: The package's own `code_assets` and `data_assets`.

    Returns:
        `hook/build.dart`, or "" when there is no hook or it is replaced.
    """
    if build_hook == None or assets:
        return ""
    return "hook/build.dart"

def _package_metadata(ctx, fetched_identity):
    root = locate_package_root(ctx.label.repo_root, ctx.label.package)
    if root.error != None:
        fail("%s: %s" % (ctx.label, root.error))
    package_root = root.root
    assets = [a[DartCodeAssetInfo] for a in ctx.attr.code_assets]
    data_assets = data_assets_of(ctx.attr.data_assets)
    linked = [a[DartLinkedCodeAssetInfo] for a in ctx.attr.linked_code_assets]
    for err in [
        link_hook_error(ctx.label, package_root, ctx.file.link_hook),
        build_hook_error(ctx.label, package_root, ctx.file.build_hook),
        check_code_asset_ownership(ctx.label, ctx.attr.package_name, assets),
        check_data_asset_ownership(ctx.label, ctx.attr.package_name, data_assets),
        check_linked_code_asset_ownership(ctx.label, ctx.attr.package_name, linked, assets),
        link_hook_assets_error(ctx.label, ctx.attr.package_name, ctx.file.link_hook, ctx.attr.link_hook_assets),
    ]:
        if err != None:
            fail(err)
    return [DartPackageMetadataInfo(
        label = ctx.label,
        package_name = ctx.attr.package_name,
        package_root = package_root,
        language_version = ctx.attr.language_version,
        version = ctx.attr.version,
        code_assets = tuple(assets),
        data_assets = tuple(data_assets),
        unreplaced_hook = unreplaced_build_hook(ctx.file.build_hook, assets + data_assets + linked),
        link_hook = ctx.file.link_hook,
        link_hook_assets = tuple(ctx.attr.link_hook_assets),
        linked_code_assets = tuple(linked),
        license_file = ctx.file.license_file,
        fetched_identity = fetched_identity,
    )]

def _dart_package_metadata_impl(ctx):
    return _package_metadata(ctx, fetched_identity = None)

def _check_in_fetched_repository(ctx, rule_name):
    if ctx.label.repo_name == "":
        fail(("%s: `%s` declares a package a fetcher fetched, " +
              "and only a fetcher's repository states one. Declare a package of the " +
              "workspace with `dart_package_metadata` (`@rules_dart//dart:defs.bzl`), " +
              "or fetch it with `pub.from_lock()` or `pub.package()`.") % (ctx.label, rule_name))

def _fetched_package_metadata_impl(ctx):
    _check_in_fetched_repository(ctx, "fetched_package_metadata")
    if not ctx.attr.purl.startswith("pkg:"):
        fail("%s: `purl` is \"%s\", which is not a purl: it starts with `pkg:`." % (ctx.label, ctx.attr.purl))
    return _package_metadata(ctx, fetched_identity = purl_identity(ctx.attr.purl))

def _fetched_path_package_metadata_impl(ctx):
    _check_in_fetched_repository(ctx, "fetched_path_package_metadata")
    return _package_metadata(ctx, fetched_identity = directory_identity(ctx.attr.repository, ctx.attr.directory))

def _fetched_local_git_package_metadata_impl(ctx):
    _check_in_fetched_repository(ctx, "fetched_local_git_package_metadata")
    if not ctx.attr.commit:
        fail("%s: `commit` is empty: a git package is fetched at a commit." % ctx.label)
    return _package_metadata(ctx, fetched_identity = local_git_identity(
        ctx.attr.repository,
        ctx.attr.directory,
        ctx.attr.commit,
        ctx.attr.package_path,
    ))

_ATTRS = {
    "package_name": attr.string(
        mandatory = True,
        doc = "The Dart package name used in `package:` imports — the `name:` from the package's `pubspec.yaml`.",
    ),
    "language_version": attr.string(
        doc = "Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form (e.g. `3.11`). Emitted as `languageVersion` in generated `package_config.json` entries, so every file of the package — its `lib/`, and the entrypoints of executables naming this target — compiles, analyzes and is format-checked at it; passed to code generators as the root language version. Leave empty to state none: the package then has the SDK's own.",
    ),
    "version": attr.string(
        doc = "The package's own version, as resolved by pub (e.g. `2.2.0`). Set by `pub.package()` / `pub.from_lock()`; leave it empty for a package you build yourself, which has no resolved version. A generated `pubspec.yaml` (for lints and code generators) states it as the constraint on the package, and when two pub repositories supply the package fetched differently, the error names each one's version. It does not make two packages of one name one package: only what a fetcher fetched does.",
    ),
    "license_file": attr.label(
        doc = "The package's license text, which a bundler collects into an app's license page (rules_flutter builds Flutter's from it). Set by `pub.from_lock()` to the package's root `NOTICES`, or `LICENSE` when it has none; Gazelle chooses the same way.",
        allow_single_file = True,
    ),
    "build_hook": attr.label(
        doc = """The package's `hook/build.dart`, if it has one. rules_dart never runs a \
build hook: the native code it would build comes from `code_assets` instead, and the data assets \
it would emit from `data_assets`. A package with a `build_hook` and neither fails every \
`dart_binary`/`dart_test` that reaches it, rather than building a program whose `@Native` \
bindings fail to resolve at run time. Must be the file at `hook/build.dart` under the package \
root. Leave it unset for a hook whose assets nothing here uses.""",
        allow_single_file = [".dart"],
    ),
    "link_hook": attr.label(
        doc = """The package's `hook/link.dart`, if it has one. A linked \
`dart_program_assets` runs it over an executable's recorded uses; nothing else does, matching \
upstream, where only a release build links. Must be the file at `hook/link.dart` under the package root. Its imports \
are ordinary `deps` of the package's library, as pub requires.""",
        allow_single_file = [".dart"],
    ),
    "link_hook_assets": attr.string_list(
        doc = """The ids (`package:<package_name>/<name>`, as `dart_data_asset.asset_id` \
takes) of the data assets `link_hook` promises: it emits each in every program, and may emit \
others, which depend on the program. Bazel names every output before anything runs, so a linked \
program declares one file per promised id, known at analysis time for a rule to name \
(`program_asset_file()`), and fails when the hook does not emit one. What else it emits is in \
the program's manifest only. Each must be the package's own, and listed once; requires \
`link_hook`.""",
    ),
    "code_assets": attr.label_list(
        doc = """Native code assets this package owns (see the `dart_code_asset` rule). \
They reach every `dart_binary`/`dart_test` that depends on any library of the package, directly \
or transitively, and every one in the package (its `package`) — matching upstream, where depending \
on a package gets you its assets with no opt-in, and the root package is like any other. Each `asset_id` must be namespaced to `package_name`. When \
the program is linked and the package has a `link_hook`, they are the hook's `LinkInput.assets` \
instead, and only those it emits ship.""",
        providers = [DartCodeAssetInfo],
    ),
    "linked_code_assets": attr.label_list(
        doc = """Native code this package links into each program (see the \
`dart_linked_code_asset` rule): what a link hook that tree-shakes a native library to the symbols \
the program uses would build. A linked program runs each one's tool over its recorded uses and \
links the library exporting just those symbols; an unlinked one links it whole. Either way it \
ships as a code asset under its `asset_id`, which must be namespaced to `package_name` and no \
id of `code_assets`.""",
        providers = [DartLinkedCodeAssetInfo],
    ),
    "data_assets": attr.label_list(
        doc = """Data assets this package owns (see the `dart_data_asset` rule): the files \
its build hook would emit as `DataAsset`s. They reach every program that depends on any library \
of the package, directly or transitively, or is in it (see `dart_program_assets`); when the \
program is linked and the package has a `link_hook`, they are the hook's `LinkInput.assets` \
instead, and ship as it decides, as a build hook routes its data assets to its own link hook \
when linking. Each `asset_id` must be \
`package:<package_name>/<name>`, each name once.""",
        providers = [DartDataAssetInfo],
    ),
}

dart_package_metadata = rule(
    implementation = _dart_package_metadata_impl,
    attrs = _ATTRS,
    provides = [DartPackageMetadataInfo],
    doc = """Declares a Dart package's facts once: the Bazel stand-in for its `pubspec.yaml`.

Every target that builds part of the package names it with `package`:
`dart_library`, `dart_codegen` and the `<builder>_codegen` macros,
`dart_aggregate_codegen`, `dart_sqlcodegen`, and the executables `dart_binary`,
`dart_test`, `dart_js_binary` and `dart_wasm_binary`. None of them states a
package fact itself, so every record of the package carries every fact,
whichever of its targets a program reaches.

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
    language_version = "3.11",
    license_file = "LICENSE",
)

dart_codegen(
    name = "model_g",
    package = ":pubspec-metadata",
    src = "lib/model.dart",
    generator = "//tools:gen",
    output_suffixes = [".g.dart"],
)

dart_library(
    name = "my_app",
    package = ":pubspec-metadata",
    srcs = ["lib/model.dart", ":model_g"],
)
```

Its name is free. It declares the package rooted at its own directory, or, in
a BUILD file under `lib/`, at the directory above that `lib`. A package has
one, as it has one `pubspec.yaml`: a program, test, library or analysis that
reaches targets naming two declarations for one root fails, naming both. Facts that differ
between libraries of the package are not package facts: native assets that
differ between programs are the `code_assets` of the executable. A library
naming it must have its sources under that root's `lib/`; an executable naming
it belongs to the package wherever its own BUILD file is
(`pkg/test/BUILD.bazel` naming `//pkg:pubspec-metadata`), so its entrypoint takes the
package's language version, as Dart gives every file under a pubspec's
directory. A target naming no `dart_package_metadata` is named after its root's
directory and states nothing else.

Gazelle writes it at each package root, named `pubspec-metadata`, from
`pubspec.yaml`, `hook/` and the license file; it adopts one already there,
whatever its name, and keeps a hand-written `code_assets`, `data_assets`,
`link_hook_assets` and `linked_code_assets`. Pub's spoke repositories write one per package.

Not to be confused with `pub.package()`, the module extension tag that fetches a
published package from pub.dev. This declares facts about a package in the
build.""",
)

_REPOSITORY_ATTR = attr.string(
    mandatory = True,
    doc = "The canonical name of the repository holding the lock, as `Label.repo_name` gives it; empty for the main repository.",
)

_FETCHED_DOC = """

Written only into the BUILD files a fetcher's repository generates, by
`make_package_metadata_content(source = ...)` (`@rules_dart//dart/pub:pub_lock_package.bzl`);
a target of the main repository fails, naming `dart_package_metadata`. Two packages of one name at different
roots are one package only when both are declared by the same one of
`fetched_package_metadata`, `fetched_local_git_package_metadata` and
`fetched_path_package_metadata`, stating the same values: the same package
fetched, or built from the same directory, by two fetchers (rules_dart's `pub`
and rules_flutter's `flutter_pub`) into repositories of their own."""

fetched_package_metadata = rule(
    implementation = _fetched_package_metadata_impl,
    attrs = dict(
        _ATTRS,
        purl = attr.string(
            mandatory = True,
            doc = "The purl of the archive or git commit fetched (`pub_hosted_purl`, `pub_git_purl`).",
        ),
    ),
    provides = [DartPackageMetadataInfo],
    doc = "`dart_package_metadata` of a package fetched as what its purl names." + _FETCHED_DOC,
)

fetched_local_git_package_metadata = rule(
    implementation = _fetched_local_git_package_metadata_impl,
    attrs = dict(
        _ATTRS,
        repository = _REPOSITORY_ATTR,
        directory = attr.string(
            mandatory = True,
            doc = "The git repository's path from that repository's root, normalized; empty for the root.",
        ),
        commit = attr.string(
            mandatory = True,
            doc = "The locked commit.",
        ),
        package_path = attr.string(
            doc = "The package's directory in the git repository, normalized; empty for its root.",
        ),
    ),
    provides = [DartPackageMetadataInfo],
    doc = "`dart_package_metadata` of a git package its lock names by a relative url: a commit of a git repository inside the lock's repository." + _FETCHED_DOC,
)

fetched_path_package_metadata = rule(
    implementation = _fetched_path_package_metadata_impl,
    attrs = dict(
        _ATTRS,
        repository = _REPOSITORY_ATTR,
        directory = attr.string(
            mandatory = True,
            doc = "The package's directory from that repository's root, normalized; empty for the root.",
        ),
    ),
    provides = [DartPackageMetadataInfo],
    doc = "`dart_package_metadata` of a `path` package built from its pubspec, by the directory it is built from." + _FETCHED_DOC,
)
