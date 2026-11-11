"""The `dart_linked_code_asset` rule.

Native code a package links into each program, as a code asset of its own: the
Bazel counterpart of a link hook that tree-shakes a native library to what the
program uses (upstream's `CLinker` with `LinkerOptions.treeshake`). The owning
package names it in the `linked_code_assets` of its `dart_package_metadata`.

A linked program runs `symbols` over its recorded uses, which maps the
`@RecordUse` uses of the package's bindings to the native symbols they reach,
and links `library` with the registered C++ toolchain into a shared library
that exports just those; an unlinked one links it whole. Each program's library
is its own, built hermetically from the program's uses.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//dart/private:package_info.bzl", "DartLinkedCodeAssetInfo", "parse_data_asset_ids")
load("//dart/private:runtime.bzl", "non_dart_transition")

visibility("//dart/...")

def _dart_linked_code_asset_impl(ctx):
    # A code-asset id has the shape of a data-asset id.
    _, err = parse_data_asset_ids(ctx.label, [ctx.attr.asset_id])
    if err != None:
        fail(err.replace("data asset id", "code asset id"))
    return [DartLinkedCodeAssetInfo(
        asset_id = ctx.attr.asset_id,
        library = ctx.attr.library[CcInfo],
        owner = ctx.attr.library.label,
        symbols = ctx.attr.symbols[DefaultInfo].files_to_run,
        name = ctx.label.name,
    )]

dart_linked_code_asset = rule(
    implementation = _dart_linked_code_asset_impl,
    # The library is the same under every web compiler, whether or not
    # creation locations are tracked and whatever environment the executable
    # above it compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = "The code-asset id the owning package's `@Native`/`@ffi.DefaultAsset` bindings use (e.g. `package:native_add/native_add`).",
        ),
        "library": attr.label(
            mandatory = True,
            providers = [CcInfo],
            doc = """The native code to link, a `cc_library`. Its own objects are linked whole, as a \
`cc_shared_library`'s `deps` are, and what it depends on as the link needs; the library a program \
ships exports only the symbols `symbols` names.""",
        ),
        "symbols": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = """The tool that maps a program's recorded uses to the symbols to keep, run as \
`<symbols> <recorded_uses.json> <output>`: it reads the uses (the JSON the Dart compiler writes, \
`package:record_use` reads it) and writes one native symbol name per line, as upstream's link \
hooks pass `LinkerOptions.treeshake(symbolsToKeep:)`. Usually a `dart_binary` over the package's \
generated mapping from Dart function to native symbol.""",
        ),
    },
    provides = [DartLinkedCodeAssetInfo],
    doc = "Native code a package links into each program, exporting the symbols the program's recorded uses reach, for the `linked_code_assets` of a `dart_package_metadata`.",
)
