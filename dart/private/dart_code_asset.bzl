"""The `dart_code_asset` rule.

Binds a native dynamic library — a `cc_shared_library`, or a prebuilt
`.so`/`.dylib`/`.dll` file — to the Dart code-asset id that the owning package's `@Native`/`@ffi.DefaultAsset` bindings
use. This is the seam between Bazel's native build and Dart's code-asset
resolution: `dart_test` / `dart_binary` consume `DartCodeAssetInfo` via their
`code_assets` attribute and synthesise the `native_assets.yaml` that
`frontend_server --native-assets` embeds into the kernel.

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
load("//dart/private:runtime.bzl", "non_dart_transition")

visibility("//dart/...")

_APPLE_OSES = ["ios", "macos", "tvos", "visionos", "watchos"]

def _library_extension(ctx):
    """The file extension of a dynamic library on the target platform."""
    if ctx.target_platform_has_constraint(ctx.attr._windows[platform_common.ConstraintValueInfo]):
        return "windows", ".dll"
    for os in _APPLE_OSES:
        if ctx.target_platform_has_constraint(getattr(ctx.attr, "_" + os)[platform_common.ConstraintValueInfo]):
            return os, ".dylib"
    return None, ".so"

def _extract_dynamic_library(ctx, library_target):
    """The dynamic-library File behind `file`.

    From a `cc_shared_library`, read from
    `CcSharedLibraryInfo.linker_input.libraries[*].dynamic_library` rather than
    `DefaultInfo.files`, which on Windows also holds the import library and
    `.pdb`. Otherwise the target must be one prebuilt library file, named as
    the target platform names one.
    """
    if CcSharedLibraryInfo in library_target:
        info = library_target[CcSharedLibraryInfo]
        libraries = info.linker_input.libraries
        if not libraries:
            fail("dart_code_asset %s: `file` %s has no libraries in its CcSharedLibraryInfo." %
                 (ctx.label, library_target.label))
        for lib in libraries:
            if lib.dynamic_library != None:
                return lib.dynamic_library
        fail("dart_code_asset %s: `file` %s has no dynamic_library File on its CcSharedLibraryInfo." %
             (ctx.label, library_target.label))

    files = library_target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail(("dart_code_asset %s: `file` %s is neither a `cc_shared_library` " +
              "nor a single prebuilt library file; it has %d files.") %
             (ctx.label, library_target.label, len(files)))
    library = files[0]
    os, extension = _library_extension(ctx)
    name = library.basename
    if not (name.endswith(extension) or (extension == ".so" and ".so." in name)):
        fail(("dart_code_asset %s: `file` file %s is not a dynamic library " +
              "for the target platform, which loads %s files%s.") %
             (ctx.label, library.short_path, extension, " (%s)" % os if os else ""))
    return library

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

    file = None
    uri = ""

    if link_mode == "dynamic_loading_bundle":
        if ctx.attr.file == None:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_bundle\" " +
                  "requires `file`, a `cc_shared_library` or a prebuilt library file.") % ctx.label)
        if ctx.attr.uri:
            fail(("dart_code_asset %s: `uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)
        file = _extract_dynamic_library(ctx, ctx.attr.file)
    elif link_mode == "dynamic_loading_system":
        if not ctx.attr.uri:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_system\" " +
                  "requires `uri = \"<uri>\"`.") % ctx.label)
        if ctx.attr.file != None:
            fail(("dart_code_asset %s: `file` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        uri = ctx.attr.uri
    else:  # dynamic_loading_executable / dynamic_loading_process
        if ctx.attr.file != None:
            fail(("dart_code_asset %s: `file` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        if ctx.attr.uri:
            fail(("dart_code_asset %s: `uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)

    files = depset([file] if file != None else [])
    return [
        DefaultInfo(files = files),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = link_mode,
            file = file,
            uri = uri,
        ),
    ]

dart_code_asset = rule(
    implementation = _dart_code_asset_impl,
    # Its outputs are the same under every web compiler, whether or not
    # creation locations are tracked and whatever environment the executable
    # above it compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = "The code-asset id the owning package's `@Native`/`@ffi.DefaultAsset` declares (e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`).",
        ),
        "link_mode": attr.string(
            default = "dynamic_loading_bundle",
            doc = """How the runtime loads this asset. One of `dynamic_loading_bundle` (a \
Bazel-built library shipped alongside the app), `dynamic_loading_system` (a library already \
present on the target system, named by `uri`), `dynamic_loading_executable`, or \
`dynamic_loading_process`. The reserved `static` mode fails fast — neither the Dart VM nor the \
Flutter engine implements it.

May be a `select()`: an ext package that bundles on one platform and uses the system library on \
another expresses that here, and consumers see a single target.""",
            values = list(CODE_ASSET_LINK_MODES) + ["static"],
        ),
        "file": attr.label(
            allow_files = True,
            doc = """The dynamic library that backs this code asset: a `cc_shared_library`, or one \
prebuilt library file (a checked-in or downloaded `.so`, `.dylib` or `.dll`, as \
`cc_import.shared_library` takes it), whose extension must be the target platform's. Required for \
`dynamic_loading_bundle`; forbidden for the other link modes.""",
        ),
        "_windows": attr.label(default = "@platforms//os:windows"),
        "_ios": attr.label(default = "@platforms//os:ios"),
        "_macos": attr.label(default = "@platforms//os:macos"),
        "_tvos": attr.label(default = "@platforms//os:tvos"),
        "_visionos": attr.label(default = "@platforms//os:visionos"),
        "_watchos": attr.label(default = "@platforms//os:watchos"),
        "uri": attr.string(
            doc = "System library URI, e.g. `libsqlite3.so.0`. Required for `dynamic_loading_system`; forbidden for the other link modes.",
        ),
    },
    provides = [DartCodeAssetInfo],
    doc = "Binds a native dynamic library, built by Bazel or prebuilt, to a Dart code-asset id, for use in `dart_test`/`dart_binary` `code_assets`.",
)
