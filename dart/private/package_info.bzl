"""`DartPackageInfo` and the asset providers its constructor checks.

Defined apart from `//dart:providers.bzl`, which re-exports them, so that the
raw constructor `raw_dart_package_info` reaches rules_dart's own code and not
rule authors: `DartPackageInfo(...)` is the checked one. The raw one states every
field, as `derived_package_info()` and `package_info_from_metadata()` do when
they copy a record whole, and builds the records tests need that the checked
one refuses.
"""

visibility("//dart/...")

DartCodeAssetInfo = provider(
    doc = """A native code asset (a Bazel-built dynamic library) bound to the \
Dart `@Native`/`@DefaultAsset` asset id the owning package uses.

Produced by the `dart_code_asset` rule and consumed via the `code_assets` \
attribute of `dart_test` / `dart_binary`, which embed the mapping into the \
compiled kernel (`frontend_server --native-assets`) so the Dart VM resolves the \
package's `@Native` symbols against the Bazel-built library at runtime.""",
    fields = {
        "asset_id": "str: The code-asset id the owning package declares (its `@ffi.DefaultAsset` / `@Native(assetId:)`), e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`.",
        "link_mode": "str: How the runtime loads the asset. One of `dynamic_loading_bundle`, `dynamic_loading_system`, `dynamic_loading_executable`, `dynamic_loading_process` — the upstream `code_assets` strings, verbatim.",
        "file": "File or None: The dynamic library (`.so`/`.dylib`/`.dll`) the asset resolves to. Set only for `dynamic_loading_bundle`; `None` otherwise.",
        "uri": "str: System library URI (e.g. `libsqlite3.so.0`) for `dynamic_loading_system`. Empty string otherwise.",
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
    }

DartPackageInfo, raw_dart_package_info = provider(
    init = _init,
    doc = """Record of a single Dart package in the build graph, carried in depsets within DartInfo.

`DartPackageInfo(...)` states a package's own facts, for a rule author whose rule \
does so itself, and checks them: the code, data and linked code assets, and \
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
    },
)
