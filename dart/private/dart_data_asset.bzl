"""The `dart_data_asset` rule.

Binds a file to the data-asset id a package's build hook would give it: the
Bazel stand-in for a `DataAsset` a `hook/build.dart` emits, as
`dart_code_asset` is for a `CodeAsset`. The owning package names it in the
`data_assets` of its `dart_package_metadata`, from where it reaches every
program depending on the package.

The provider is `DartDataAssetInfo`, the one `dart_link_hook` gives a linked
program's assets in, so a declared asset and one a link hook emits reach a
bundler the same way.
"""

load("//dart:providers.bzl", "DartDataAssetInfo")
load("//dart/private:runtime.bzl", "non_dart_transition")

visibility("//dart/...")

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

def data_asset(package, name, file):
    """One data asset, as `DartDataAssetInfo.assets` holds it.

    Args:
      package: The owning package.
      name: The asset's name within the package.
      file: The File.

    Returns:
      A `struct(package, name, file, id)`.
    """
    return struct(package = package, name = name, file = file, id = "package:%s/%s" % (package, name))

def _dart_data_asset_impl(ctx):
    parsed, err = parse_data_asset_ids(ctx.label, [ctx.attr.asset_id])
    if err != None:
        fail(err)
    asset = data_asset(parsed[0].package, parsed[0].name, ctx.file.src)
    return [
        DefaultInfo(files = depset([ctx.file.src])),
        DartDataAssetInfo(assets = depset([asset])),
    ]

dart_data_asset = rule(
    implementation = _dart_data_asset_impl,
    # A file is the same under every web compiler, whether or not creation
    # locations are tracked and whatever environment the executable above it
    # compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = """The id the package's build hook gives the asset, `package:<package>/<name>`: \
`<package>` is the package whose `dart_package_metadata` names this target, and `<name>` the \
`DataAsset.name` the hook would use, a relative path (e.g. `package:glyphs/glyphs/all.json`).""",
        ),
        "src": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The file, a source file or one a rule generates.",
        ),
    },
    provides = [DartDataAssetInfo],
    doc = "Binds a file to a Dart data-asset id, for the `data_assets` of a `dart_package_metadata`.",
)
