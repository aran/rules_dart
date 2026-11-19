"""`DartPackageInfo` and the asset providers its constructor checks.

Defined apart from `//dart:providers.bzl`, which re-exports them, so that the
raw constructor `raw_dart_package_info` reaches rules_dart's own code and not
rule authors: `DartPackageInfo(...)` is the checked one. The raw one states every
field, as `derived_package_info()` and `package_info_from_metadata()` do when
they copy a record whole, and builds the records tests need that the checked
one refuses.
"""

visibility("//dart/...")

_LINK_INPUTS_UNSET_BY_DEFAULT = (
    "the rule that provided this code asset did not state what its library was " +
    "linked from. That rule should pass `link_inputs`, a depset of the files the " +
    "library was linked from, when it builds `DartCodeAssetInfo`, or bind the " +
    "library with `dart_code_asset`, which reads them from the link."
)

_LINK_INPUTS_GONE_BY_DEFAULT = (
    "the rule that provided this code asset states that what its library was " +
    "linked from no longer exists."
)

def check_dsym(provider, dsym):
    """Fails unless `dsym` is a `.dSYM` directory.

    Args:
      provider: The name of the provider being built, for the message.
      dsym: The File.
    """
    if not dsym.is_directory or not dsym.basename.endswith(".dSYM"):
        fail(("%s: `dsym` must be a `.dSYM` directory, as `ctx.actions.declare_directory` " +
              "declares one, got %s.") % (provider, dsym.short_path))

def _code_asset_init(
        asset_id,
        link_mode,
        file,
        uri,
        link_inputs = None,
        link_inputs_unset_reason = None,
        link_inputs_gone = False,
        dsym = None):
    # What the library was linked from is a fact stated one way: the files when
    # they are known, and otherwise the reason they are not. A rule that says
    # neither is a rule that did not think of it, which a consumer deserves to
    # hear as such rather than as an empty link.
    if link_inputs != None and type(link_inputs) != "depset":
        fail("DartCodeAssetInfo: `link_inputs` must be a depset of Files or None, got %s." % type(link_inputs))
    if link_inputs_unset_reason != None and type(link_inputs_unset_reason) != "string":
        fail("DartCodeAssetInfo: `link_inputs_unset_reason` must be a string or None, got %s." % type(link_inputs_unset_reason))
    if link_inputs != None and link_inputs_unset_reason != None:
        fail(("DartCodeAssetInfo %s: states both `link_inputs` and `link_inputs_unset_reason`. " +
              "Pass `link_inputs` when it is known, and the reason when it is not.") % asset_id)

    # Whether the files are gone says why they are not known, so it means
    # something only where they are not.
    if type(link_inputs_gone) != "bool":
        fail("DartCodeAssetInfo: `link_inputs_gone` must be a bool, got %s." % type(link_inputs_gone))
    if link_inputs_gone and link_inputs != None:
        fail(("DartCodeAssetInfo %s: states `link_inputs_gone` with `link_inputs`. " +
              "Files that are known are not gone; pass one or the other.") % asset_id)
    if link_inputs == None and link_inputs_unset_reason == None:
        link_inputs_unset_reason = "%s: %s" % (
            asset_id,
            _LINK_INPUTS_GONE_BY_DEFAULT if link_inputs_gone else _LINK_INPUTS_UNSET_BY_DEFAULT,
        )

    # A dSYM describes a library, so there is none without one.
    if dsym != None:
        if type(dsym) != "File":
            fail("DartCodeAssetInfo: `dsym` must be a File or None, got %s." % type(dsym))
        check_dsym("DartCodeAssetInfo", dsym)
        if file == None:
            fail("DartCodeAssetInfo %s: states `dsym` but has no `file` for it to describe." % asset_id)
    return {
        "asset_id": asset_id,
        "link_mode": link_mode,
        "file": file,
        "uri": uri,
        "link_inputs": link_inputs,
        "link_inputs_unset_reason": link_inputs_unset_reason,
        "link_inputs_gone": link_inputs_gone,
        "dsym": dsym,
    }

DartCodeAssetInfo, _raw_code_asset_info = provider(
    init = _code_asset_init,
    doc = """A native code asset (a Bazel-built dynamic library) bound to the \
Dart `@Native`/`@DefaultAsset` asset id the owning package uses.

Produced by the `dart_code_asset` rule and consumed via the `code_assets` \
attribute of `dart_test` / `dart_binary`, which embed the mapping into the \
compiled kernel (`frontend_server --native-assets`) so the Dart VM resolves the \
package's `@Native` symbols against the Bazel-built library at runtime.

A rule building one states `asset_id`, `link_mode`, `file` and `uri`, and \
`link_inputs` when it knows what `file` was linked from, or \
`link_inputs_unset_reason` when it does not. Stating neither leaves \
`link_inputs` unset with a reason saying so; stating both fails. When it \
knows the files existed and were deleted, as a rule whose action links and \
deletes its objects does, it states `link_inputs_gone = True` instead of \
`link_inputs`; stating both fails. It states `dsym` when it has the dSYM of \
`file`.""",
    fields = {
        "asset_id": "str: The code-asset id the owning package declares (its `@ffi.DefaultAsset` / `@Native(assetId:)`), e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`.",
        "link_mode": "str: How the runtime loads the asset. One of `dynamic_loading_bundle`, `dynamic_loading_system`, `dynamic_loading_executable`, `dynamic_loading_process` — the upstream `code_assets` strings, verbatim.",
        "file": "File or None: The dynamic library (`.so`/`.dylib`/`.dll`) the asset resolves to. Set only for `dynamic_loading_bundle`; `None` otherwise.",
        "uri": "str: System library URI (e.g. `libsqlite3.so.0`) for `dynamic_loading_system`. Empty string otherwise.",
        "link_inputs": "depset[File] or None: What `file` was linked from, for an action that reads those files again, as `dsymutil` does: at least every object file and static archive of the link (the objects of a library with no archive too), and possibly the rest of its inputs, such as linker tools. From the C++ link action of the target `dart_code_asset` binds, or what that target states in `DartLinkInputsInfo`. Empty for a prebuilt library and when there is no `file`. `None` when it is not known: a rule that is no `filegroup` forwards a library another target wrote (a platform transition does, and the library is bound all the same), an action that does not link wrote it (a copy), the action that linked it deleted the files (rustc, which makes the object file it links inside the action: `link_inputs_gone` is then `True`), or the rule that built this provider did not state it. A consumer that needs it tests for `None` and `fail()`s with `link_inputs_unset_reason`, unless `link_inputs_gone` says nothing will ever do better. Pass it to an action's `inputs` as it is: nothing is computed until then.",
        "link_inputs_unset_reason": "str or None: Why `link_inputs` is `None` and what to do about it; `None` when `link_inputs` is known. For a consumer that needs `link_inputs` to `fail()` with.",
        "link_inputs_gone": "bool: Whether the files `file` was linked from existed and no longer do, which is why `link_inputs` is `None`: the action that linked it deleted them, as rustc deletes the crate's object file. Meaningful only when `link_inputs` is `None`, and always `False` when it is known. `False` with `link_inputs` `None` means the link is out of sight, which a consumer can often mend by naming the target that linked the library (see `link_inputs_unset_reason`); `True` means no tool run later can do better, so a consumer that has a fallback for a library without its objects, such as a dSYM holding only a symbol table, takes it instead of failing. A consumer wanting debug symbols tests, in order, `dsym`, `link_inputs`, `link_inputs_gone`, and fails with `link_inputs_unset_reason` after those.",
        "dsym": "File or None: The `.dSYM` directory of `file` on Apple platforms, made when `file` was and ready to use as it is. A consumer that wants debug symbols takes this when it is set and otherwise runs `dsymutil` over `link_inputs`. It is the only way to the line tables of a library whose object files are gone, as a `rust_shared_library`'s are. Set when the action that wrote `file` also wrote `<file's name>.dSYM` next to any other output (rustc does; so does a `cc_binary` link under `--apple_generate_dsym`), or when the target `dart_code_asset` binds states it in `DartDsymInfo`. `None` otherwise, including for a `cc_shared_library`, whose link writes none, and on other platforms. What it holds is what the build put there, which analysis cannot see: rustc leaves the directory empty unless the crate is compiled with debug information, as under `-c dbg`, so a consumer must accept an empty one.",
    },
)

DartLinkedCodeAssetInfo = provider(
    doc = """Native code a package links into each program that uses it: the \
Bazel counterpart of a link hook that tree-shakes a native library to the \
symbols a program's recorded uses reach.

Produced by `dart_linked_code_asset` and named in the `linked_code_assets` of \
a `dart_package_metadata`. A linked program runs `symbols` over its recorded \
uses and links `library` into a shared library exporting just those symbols, \
shipped as the code asset `asset_id`; an unlinked one links it whole.""",
    fields = {
        "asset_id": "str: The code-asset id the package's `@Native` bindings use, `package:<package>/<name>`.",
        "library": "CcInfo: The native code to link, as a `cc_library` provides it.",
        "owner": "Label: The target `library` came from, whose own objects are linked whole, as a `cc_shared_library`'s `deps` are; what they depend on is linked as needed.",
        "symbols": "FilesToRunProvider: The tool mapping a program's recorded uses to the symbols to keep, run as `symbols <recorded_uses.json> <output>`; it writes one symbol name per line.",
        "name": "str: The library's name, `lib<name>.so` (`.dylib`, `<name>.dll`) in a program.",
    },
)

DartDataAssetInfo = provider(
    doc = """Data assets: files a Dart program reads at run time by asset id, \
the counterpart of `DartCodeAssetInfo` for data rather than native code.

Produced by `dart_data_asset`, one asset a package declares in the \
`data_assets` of its `dart_package_metadata`, standing in for one its build \
hook would emit. What a program ships is `DartProgramAssetsInfo`'s. Carries \
only what upstream's `DataAsset` carries — package, name, file — and no \
bundling paths: where the file lands inside an application is the bundler's \
decision (rules_flutter's, for a Flutter app).""",
    fields = {
        "assets": "depset[struct]: One struct per data asset, with `package` (str: the owning package), `name` (str: the asset's name within the package, e.g. `glyphs/index.json`), `file` (File) and `id` (str: `package:<package>/<name>`, the id Dart code loads it by).",
    },
)

def check_code_asset_ownership(label, package_name, assets):
    """Checks that every declared asset id is namespaced to this package.

    Upstream requires `CodeAsset.id` to be `package:<package>/<name>` where
    `<package>` is the package that owns the asset — "Code assets are
    name-spaced in their own package to avoid naming conflicts". Since assets
    ride `DartPackageInfo`, an id belonging to some other package would
    propagate under the wrong owner and be impossible to trace back.

    Args:
      label: The owning rule's label (included in the error message).
      package_name: The package name this library declares.
      assets: List of `DartCodeAssetInfo`.

    Returns:
      An error message string on the first mismatch, else `None`.
    """
    prefix = "package:%s/" % package_name
    for asset in assets:
        if not asset.asset_id.startswith(prefix):
            return (
                ("%s: code asset id `%s` is not namespaced to this package. " +
                 "Expected it to start with `%s`, because a code asset is " +
                 "owned by the package declaring it. Move the asset to the " +
                 "`dart_package_metadata` of the package its id names.") %
                (label, asset.asset_id, prefix)
            )
    return None

def check_linked_code_asset_ownership(label, package_name, linked, code_assets):
    """Checks that every linked code asset is the package's own, and named once.

    Args:
      label: The owning rule's label (included in the error message).
      package_name: The package name this target declares.
      linked: List of `DartLinkedCodeAssetInfo`.
      code_assets: The package's `DartCodeAssetInfo`, whose ids none may share.

    Returns:
      An error message string on the first problem, else `None`.
    """
    prefix = "package:%s/" % package_name
    seen = {a.asset_id: True for a in code_assets}
    for asset in linked:
        if not asset.asset_id.startswith(prefix):
            return (("%s: linked code asset id `%s` is not namespaced to this " +
                     "package. Expected it to start with `%s`, because a code " +
                     "asset is owned by the package declaring it.") %
                    (label, asset.asset_id, prefix))
        if asset.asset_id in seen:
            return ("%s: code asset id `%s` is declared twice: a package's " +
                    "`code_assets` and `linked_code_assets` name each id once.") % (label, asset.asset_id)
        seen[asset.asset_id] = True
    return None

def check_data_asset_ownership(label, package_name, assets):
    """Checks that every data asset is the package's own, and named once.

    Upstream requires a build hook's `DataAsset.package` to be the hook's own
    package, and its names to be unique within it: the id
    `package:<package>/<name>` is how Dart code finds the file.

    Args:
      label: The owning rule's label (included in the error message).
      package_name: The package name this target declares.
      assets: List of `struct(package, name, file, id)`.

    Returns:
      An error message string on the first problem, else `None`.
    """
    seen = {}
    for asset in assets:
        if asset.package != package_name:
            return (
                ("%s: data asset id `%s` is not namespaced to this package. " +
                 "Expected it to start with `package:%s/`, because a data " +
                 "asset is owned by the package declaring it. Move the asset " +
                 "to the `dart_package_metadata` of the package its id names.") %
                (label, asset.id, package_name)
            )
        if asset.id in seen:
            return ("%s: data asset id `%s` is declared twice, by `%s` and `%s`." %
                    (label, asset.id, seen[asset.id].short_path, asset.file.short_path))
        seen[asset.id] = asset.file
    return None

def parse_data_asset_ids(label, ids):
    """Splits data asset ids into package and name.

    Args:
      label: The rule's label, for messages.
      ids: The ids, each `package:<package>/<name>`.

    Returns:
      `(assets, error)`: a list of `struct(package, name, id)` in declaration
      order, and None; or None and an error string.
    """
    assets = []
    seen = {}
    for asset_id in ids:
        rest = asset_id[len("package:"):] if asset_id.startswith("package:") else ""
        package, _, name = rest.partition("/")
        segments = name.split("/")
        if not package or not name or "" in segments or "." in segments or ".." in segments:
            return None, ("%s: data asset id `%s` is not of the form " +
                          "`package:<package>/<name>`, with `<name>` a relative " +
                          "path.") % (label, asset_id)
        if asset_id in seen:
            return None, "%s: data asset id `%s` is declared twice." % (label, asset_id)
        seen[asset_id] = True
        assets.append(struct(package = package, name = name, id = asset_id))
    return assets, None

def link_hook_assets_error(label, package_name, link_hook, ids):
    """Checks a package's `link_hook_assets`: the data assets its link hook promises.

    Bazel names every output before anything runs, so the ids a hook always
    emits are stated with the package, as its hook is, for a rule to name at
    analysis time. A link hook emits only its own package's data assets.

    Args:
      label: The declaring target's label, for the message.
      package_name: The package the ids must belong to.
      link_hook: The package's `link_hook` File, or None.
      ids: The ids, each `package:<package>/<name>`.

    Returns:
      An error string, or None.
    """
    if not ids:
        return None
    if link_hook == None:
        return ("%s: `link_hook_assets` %s are stated for package `%s`, which " +
                "has no `link_hook`. They name what its `hook/link.dart` emits: " +
                "set `link_hook`, or remove them.") % (label, list(ids), package_name)
    parsed, err = parse_data_asset_ids(label, ids)
    if err != None:
        return err
    for asset in parsed:
        if asset.package != package_name:
            return ("%s: link-hook asset id `%s` is not namespaced to this " +
                    "package. Expected it to start with `package:%s/`, because " +
                    "a link hook emits only its own package's data assets.") % (
                label,
                asset.id,
                package_name,
            )
    return None

def data_assets_of(targets):
    """The data assets of targets providing `DartDataAssetInfo`, in order.

    Args:
      targets: Targets providing `DartDataAssetInfo`.

    Returns:
      List of `struct(package, name, file, id)`.
    """
    return [asset for t in targets for asset in t[DartDataAssetInfo].assets.to_list()]

def purl_identity(purl):
    """The fetched identity of an archive or git commit its purl names.

    Args:
      purl: The purl (`pub_hosted_purl`, `pub_git_purl`).

    Returns:
      A `DartPackageInfo.fetched_identity`.
    """
    return struct(kind = "purl", purl = purl)

def directory_identity(repository, directory):
    """The fetched identity of a `path` package: the directory it is built from.

    Args:
      repository: The canonical name of the repository holding it, "" for the
        main repository.
      directory: Its path from that repository's root, normalized; "" for the
        root.

    Returns:
      A `DartPackageInfo.fetched_identity`.
    """
    return struct(kind = "directory", repository = repository, directory = directory)

def local_git_identity(repository, directory, commit, package_path):
    """The fetched identity of a commit of a git repository inside a lock's repository.

    A lock's relative git url names such a repository, which only the lock's
    place says: the same url in another lock names another.

    Args:
      repository: The canonical name of the repository holding the lock, ""
        for the main repository.
      directory: The git repository's path from that repository's root,
        normalized; "" for the root.
      commit: The locked commit.
      package_path: The package's directory in the git repository, normalized;
        "" for its root.

    Returns:
      A `DartPackageInfo.fetched_identity`.
    """
    return struct(
        kind = "local_git",
        repository = repository,
        directory = directory,
        commit = commit,
        package_path = package_path,
    )

def fetched_identity_text(identity):
    """A `fetched_identity` as messages write it.

    For people only: identities are compared as they are, never as this text.

    Args:
      identity: A `DartPackageInfo.fetched_identity`, not None.

    Returns:
      The purl; `@@<repo>//<directory>` for a directory; or
      `git+@@<repo>//<directory>@<commit>`, with `#<package_path>` for a package
      below the git repository's root.
    """
    if identity.kind == "purl":
        return identity.purl
    where = "@@{}//{}".format(identity.repository, identity.directory)
    if identity.kind == "directory":
        return where
    below = "#" + identity.package_path if identity.package_path else ""
    return "git+{}@{}{}".format(where, identity.commit, below)

def check_package_name(label, package_name):
    """Fails when a package record would have no name.

    Args:
      label: The constructing rule's label, for the error.
      package_name: The record's `package_name`.
    """
    if not package_name:
        fail(("%s: `package_name` is empty. A target that contributes no " +
              "package is what `dart_info_no_package()` and " +
              "`dart_analyzable_info_no_package()` are for.") % label)

def _init(
        label,
        package_name,
        package_root,
        language_version,
        code_assets = [],
        data_assets = [],
        unreplaced_hook = "",
        version = "",
        link_hook = None,
        link_hook_assets = [],
        linked_code_assets = [],
        license_file = None):
    # `language_version` has no default: omitting it and stating `""` are
    # different intentions. An absent `languageVersion` in `package_config.json`
    # is not "no language version" but the current SDK's, so a forgotten argument
    # would compile the package under newer semantics than its pubspec allows.
    # `""` stays legal and keeps its meaning.
    check_package_name(label, package_name)
    own_assets = [dep[DartCodeAssetInfo] for dep in code_assets]
    own_data = data_assets_of(data_assets)
    own_linked = [dep[DartLinkedCodeAssetInfo] for dep in linked_code_assets]
    for err in [
        check_code_asset_ownership(label, package_name, own_assets),
        check_linked_code_asset_ownership(label, package_name, own_linked, own_assets),
        check_data_asset_ownership(label, package_name, own_data),
        link_hook_assets_error(label, package_name, link_hook, link_hook_assets),
    ]:
        if err != None:
            fail(err)
    return {
        "label": label,
        "package_name": package_name,
        "package_root": package_root,
        "version": version,
        "language_version": language_version,
        "code_assets": tuple(own_assets),
        "data_assets": tuple(own_data),
        "unreplaced_hook": unreplaced_hook,
        "link_hook": link_hook,
        "link_hook_assets": tuple(link_hook_assets),
        "linked_code_assets": tuple(own_linked),
        "license_file": license_file,
        "metadata": None,
        "fetched_identity": None,
    }

DartPackageInfo, raw_dart_package_info = provider(
    init = _init,
    doc = """Record of a single Dart package in the build graph, carried in depsets within DartInfo.

`DartPackageInfo(...)` states a package's own facts, for a rule author whose rule \
does so itself, and checks them (it states no `fetched_identity`): the code, data and linked code assets, and \
the `link_hook_assets` ids, which need a `link_hook`, must be the package's own, \
`package_name` must not be empty, and `language_version` must be passed, as \
`""` when the package states none. Its `code_assets`, `data_assets` and \
`linked_code_assets` take the targets providing `DartCodeAssetInfo`, \
`DartDataAssetInfo` and `DartLinkedCodeAssetInfo`, not the values the fields \
then hold. A rule whose target names a `dart_package_metadata` builds its \
record with `package_info_from_metadata()` instead, and a record copied from \
another goes through `derived_package_info()`.""",
    fields = {
        "label": "Label or None: The target that stated this record — for a merged record, the first of the targets whose records were merged. Read only for error messages, which name the targets whose statements disagree.",
        "package_name": "str: The Dart package name. Required.",
        "package_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent. Required; empty string for the root package.",
        "version": "str: The package's own version, as resolved by pub (e.g. `2.2.0`). Optional; empty string when unknown. Recorded so that two records for one package name can be checked for agreement — see `package_agreement_error`.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Optional; empty string when unknown.",
        "code_assets": "tuple[DartCodeAssetInfo]: Native code assets this package owns. A tuple rather than a list because `DartPackageInfo` is carried in a depset, whose elements must be hashable.",
        "data_assets": "tuple[struct]: Data assets this package owns, each as `DartDataAssetInfo.assets` holds one. What a program ships of them is its `DartProgramAssetsInfo`'s.",
        "unreplaced_hook": "str: Path of a `hook/build.dart` this package ships that has no Bazel replacement (empty when none). Merged across a package's records: unreplaced when any states one and none has `code_assets` or `data_assets`. Acted on by `dart_binary`/`dart_test`.",
        "link_hook": "File or None: The package's `hook/link.dart`, which a linked program runs (`dart_program_assets`). Optional; `None` when the package has none.",
        "link_hook_assets": "tuple[str]: The ids (`package:<package>/<name>`) of the data assets the package's `link_hook` promises: it emits each in every program, and may emit others. A linked program declares a File for each, known at analysis time. Empty when it promises none.",
        "linked_code_assets": "tuple[DartLinkedCodeAssetInfo]: Native code the package links into each program, as a code asset of its own. Empty when none.",
        "license_file": "File or None: The package's license text — for a pub package, the `NOTICES` file at its root if it has one, else its `LICENSE`, the file `flutter build` collects for the license page. Optional; `None` when the package has none. Read it with `package_license_file()` from `//dart:utils.bzl`.",
        "metadata": "Label or None: The `dart_package_metadata` the record was built from (`package_info_from_metadata()`), or `None` for a package that names none. Records of one package rooted at one directory must name the same one.",
        "fetched_identity": "struct or None: What a fetcher fetched this package as, by its `kind`: `purl`, with `purl` (`pub_hosted_purl`, `pub_git_purl`), naming the registry, version and archive checksum, or the git repository, commit and path; `local_git`, for a git package locked by a url relative to the lock, with `repository` (the canonical name of the lock's repository), `directory` (the git repository's path in it), `commit` and `package_path`; or `directory`, for a `path` package a fetcher builds from its pubspec, with `repository` and `directory`. `None` for a package built in the workspace. Records of one name rooted apart are one package only when each has one and they are equal. Not stated by `DartPackageInfo(...)` or `dart_package_metadata`: only a fetcher's generated BUILD file states it, through `make_package_metadata_content()`.",
    },
)
