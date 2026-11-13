"""A `sky_engine` as Flutter ships one: the SDK's libraries and `dart:ui`, mapped by its `_embedder.yaml`."""

load("//dart:providers.bzl", "DartInfo")
load(
    "//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "PORTABLE_EXEC_GROUPS",
    "SUMMARY_ATTRS",
    "dart_info",
    "library_package",
    "package_identity_attrs",
)
load("//dart/private:common.bzl", "sdk_path_from_dart")
load("//dart/private:exec_groups.bzl", "portable_sdk")

def _sdk_embedder_engine_impl(ctx):
    sdk = portable_sdk(ctx)
    lib = sdk_path_from_dart(sdk.dart) + "/lib/"
    copies = []
    for f in sdk.files.codegen.to_list():
        if f.path.startswith(lib) and f.extension == "dart":
            out = ctx.actions.declare_file("lib/" + f.path[len(lib):])
            ctx.actions.symlink(output = out, target_file = f)
            copies.append(out)

    # Its own files beside the copies, so that the `lib/` the analyzer finds
    # `_embedder.yaml` in holds every library it maps, as one directory does
    # in Flutter's.
    own = {}
    for f in ctx.files.srcs + ctx.files.resources:
        out = ctx.actions.declare_file(f.short_path[len(ctx.label.package) + 1:])
        ctx.actions.symlink(output = out, target_file = f)
        own[f] = out
    srcs = [own[f] for f in ctx.files.srcs] + copies
    resources = [own[f] for f in ctx.files.resources]
    package = library_package(ctx, srcs, resources)
    return [
        DefaultInfo(files = depset(srcs)),
        dart_info(
            ctx = ctx,
            packages = [package.record],
            srcs = srcs,
            resources = resources,
        ),
    ]

sdk_embedder_engine = rule(
    implementation = _sdk_embedder_engine_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"], doc = "The engine's own libraries (`dart:ui`)."),
        "resources": attr.label_list(allow_files = True, doc = "`lib/_embedder.yaml`."),
    } | package_identity_attrs() | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    provides = [DartInfo],
    doc = "A `sky_engine`: the SDK's libraries beside `srcs`, as Flutter's carries them.",
)
