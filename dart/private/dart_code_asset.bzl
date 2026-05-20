"""The `dart_code_asset` rule.

Binds a `cc_shared_library` (a Bazel-built native dynamic library) to the Dart
code-asset id that the owning package's `@Native`/`@ffi.DefaultAsset` bindings
use. This is the seam between Bazel's native build and Dart's code-asset
resolution: `dart_test` / `dart_binary` consume `DartCodeAssetInfo` via their
`code_assets` attribute and synthesise the `native_assets.yaml` that
`gen_kernel --native-assets` embeds into the kernel.

Two-tier usage: a native-asset-owning package can ship a target exposing
`DartCodeAssetInfo` itself; otherwise rules_dart provides one under
`//dart/ext/<package>` (see `//dart/ext/sqlite3`).
"""

load("//dart:providers.bzl", "DartCodeAssetInfo")

# Extensions of a loadable dynamic library, per platform. A Windows
# `cc_shared_library` also emits an import library (`.lib`) and possibly a
# `.pdb`; those are excluded so we bind to the actual loadable artifact.
_DYNAMIC_LIB_EXTS = ["so", "dylib", "dll"]

def _dart_code_asset_impl(ctx):
    files = ctx.attr.shared_library[DefaultInfo].files.to_list()
    libs = [f for f in files if f.extension in _DYNAMIC_LIB_EXTS]
    if len(libs) == 0:
        fail(("dart_code_asset %s: `shared_library` %s produced no loadable " +
              "dynamic library (.so/.dylib/.dll). Files: %s") %
             (ctx.label, ctx.attr.shared_library.label, [f.short_path for f in files]))
    if len(libs) > 1:
        fail(("dart_code_asset %s: `shared_library` %s produced more than one " +
              "dynamic library: %s. Point `shared_library` at a single " +
              "cc_shared_library.") %
             (ctx.label, ctx.attr.shared_library.label, [f.short_path for f in libs]))
    lib = libs[0]
    return [
        DefaultInfo(files = depset([lib])),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            dynamic_library = lib,
        ),
    ]

dart_code_asset = rule(
    implementation = _dart_code_asset_impl,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = "The code-asset id the owning package's `@Native`/`@ffi.DefaultAsset` declares (e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`).",
        ),
        "shared_library": attr.label(
            mandatory = True,
            doc = "A `cc_shared_library` target whose `.so`/`.dylib`/`.dll` output backs this code asset.",
        ),
    },
    provides = [DartCodeAssetInfo],
    doc = "Binds a Bazel-built native dynamic library to a Dart code-asset id, for use in `dart_test`/`dart_binary` `code_assets`.",
)
