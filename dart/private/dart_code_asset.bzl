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

`DartCodeAssetInfo` deliberately carries only what upstream's `CodeAsset`
carries — id, link mode, and the library. Bundling concerns (where the file
lands inside an application, what it is renamed to) belong to the consumer;
rules_flutter layers those on top of this provider rather than rules_dart
guessing at them.
"""

load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES", "DartCodeAssetInfo")

def _extract_dynamic_library(ctx, library_target):
    """Pull the dynamic-library File out of a `cc_shared_library` target.

    `cc_shared_library` advertises its produced shared library through
    `CcSharedLibraryInfo.linker_input.libraries[*].dynamic_library`. Reading it
    there rather than filtering `DefaultInfo.files` by extension avoids having
    to exclude the Windows import library (`.lib`) and `.pdb`.
    """
    info = library_target[CcSharedLibraryInfo]
    libraries = info.linker_input.libraries
    if not libraries:
        fail("dart_code_asset %s: `shared_library` %s has no libraries in its CcSharedLibraryInfo." %
             (ctx.label, library_target.label))
    for lib in libraries:
        if lib.dynamic_library != None:
            return lib.dynamic_library
    fail("dart_code_asset %s: `shared_library` %s has no dynamic_library File on its CcSharedLibraryInfo." %
         (ctx.label, library_target.label))

def _dart_code_asset_impl(ctx):
    link_mode = ctx.attr.link_mode

    if link_mode == "static":
        fail(("dart_code_asset %s: link_mode = \"static\" is reserved by the " +
              "Dart SDK but implemented by neither the Dart VM nor the " +
              "Flutter engine. Track upstream support at " +
              "https://github.com/dart-lang/sdk/issues/49418. Use " +
              "`dynamic_loading_bundle` until that lands.") % ctx.label)

    if link_mode not in CODE_ASSET_LINK_MODES:
        fail("dart_code_asset %s: invalid link_mode %r. Expected one of: %s." %
             (ctx.label, link_mode, ", ".join(CODE_ASSET_LINK_MODES)))

    dynamic_library = None
    system_uri = ""

    if link_mode == "dynamic_loading_bundle":
        if ctx.attr.shared_library == None:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_bundle\" " +
                  "requires `shared_library = <cc_shared_library>`.") % ctx.label)
        if ctx.attr.system_uri:
            fail(("dart_code_asset %s: `system_uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)
        dynamic_library = _extract_dynamic_library(ctx, ctx.attr.shared_library)
    elif link_mode == "dynamic_loading_system":
        if not ctx.attr.system_uri:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_system\" " +
                  "requires `system_uri = \"<uri>\"`.") % ctx.label)
        if ctx.attr.shared_library != None:
            fail(("dart_code_asset %s: `shared_library` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        system_uri = ctx.attr.system_uri
    else:  # dynamic_loading_executable / dynamic_loading_process
        if ctx.attr.shared_library != None:
            fail(("dart_code_asset %s: `shared_library` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        if ctx.attr.system_uri:
            fail(("dart_code_asset %s: `system_uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)

    files = depset([dynamic_library] if dynamic_library != None else [])
    return [
        DefaultInfo(files = files),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = link_mode,
            dynamic_library = dynamic_library,
            system_uri = system_uri,
        ),
    ]

dart_code_asset = rule(
    implementation = _dart_code_asset_impl,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = "The code-asset id the owning package's `@Native`/`@ffi.DefaultAsset` declares (e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`).",
        ),
        "link_mode": attr.string(
            default = "dynamic_loading_bundle",
            doc = """How the runtime loads this asset. One of `dynamic_loading_bundle` (a \
Bazel-built library shipped alongside the app), `dynamic_loading_system` (a library already \
present on the target system, named by `system_uri`), `dynamic_loading_executable`, or \
`dynamic_loading_process`. The reserved `static` mode fails fast — neither the Dart VM nor the \
Flutter engine implements it.

May be a `select()`: an ext package that bundles on one platform and uses the system library on \
another expresses that here, and consumers see a single target.""",
            values = list(CODE_ASSET_LINK_MODES) + ["static"],
        ),
        "shared_library": attr.label(
            providers = [CcSharedLibraryInfo],
            doc = "A `cc_shared_library` target whose dynamic library backs this code asset. Required for `dynamic_loading_bundle`; forbidden for the other link modes.",
        ),
        "system_uri": attr.string(
            doc = "System library URI, e.g. `libsqlite3.so.0`. Required for `dynamic_loading_system`; forbidden for the other link modes.",
        ),
    },
    provides = [DartCodeAssetInfo],
    doc = "Binds a Bazel-built native dynamic library to a Dart code-asset id, for use in `dart_test`/`dart_binary` `code_assets`.",
)
