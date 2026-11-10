"""Rules of other rule sets, to pin where analysis against summaries finds them.

`reach_holder` is what rules_flutter's `flutter_application` is to rules_dart:
no `DartInfo`, a `DartAnalyzableInfo` naming the libraries it holds and its
entrypoint. `reach_wrapper` is a rule of a third rule set that knows nothing of
Dart (rules_apple's bundle), holding the application in a provider of its own;
`reach_outer` (rules_flutter's `flutter_apple_app`) passes on the
`DartAnalyzableInfo` it reads off that provider. The libraries are then reachable
from the outer target through no Dart attribute at all, only through the
providers.

`analysis_only_library` is a `flutter_library`: its `DartInfo` leaves out an
engine its analyzer reads (`sky_engine`, for `dart:ui`), which its
`DartAnalyzableInfo` and its summary take. `undeclared_library` builds its
`DartInfo` with `dart_info()` in a rule that declares nothing for summaries.
"""

load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load(
    "//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "PORTABLE_EXEC_GROUPS",
    "SUMMARY_ATTRS",
    "dart_analyzable_info",
    "dart_analyzable_info_no_package",
    "dart_info",
    "library_package",
    "package_identity_attrs",
)

def _holder_impl(ctx):
    return [
        DefaultInfo(),
        dart_analyzable_info_no_package(deps = ctx.attr.deps, entry_srcs = ctx.files.srcs),
    ]

reach_holder = rule(
    implementation = _holder_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "deps": attr.label_list(providers = [DartInfo]),
    },
)

WrappedInfo = provider(
    doc = "What a rule of a rule set that knows nothing of Dart holds of its application.",
    fields = {"held": "struct: the application's providers"},
)

def _wrapper_impl(ctx):
    return [DefaultInfo(), WrappedInfo(held = struct(analyzable = ctx.attr.application[DartAnalyzableInfo]))]

reach_wrapper = rule(
    implementation = _wrapper_impl,
    attrs = {"application": attr.label(mandatory = True)},
)

def _outer_impl(ctx):
    return [DefaultInfo(), ctx.attr.bundle[WrappedInfo].held.analyzable]

reach_outer = rule(
    implementation = _outer_impl,
    attrs = {"bundle": attr.label(providers = [WrappedInfo], mandatory = True)},
)

def _analysis_only_library_impl(ctx):
    package = library_package(ctx, ctx.files.srcs)
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        dart_info(
            ctx = ctx,
            packages = [package.record],
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            analysis_deps = [ctx.attr.engine],
        ),
        dart_analyzable_info(
            label = ctx.label,
            packages = [package.record],
            deps = ctx.attr.deps + [ctx.attr.engine],
            srcs = ctx.files.srcs,
        ),
    ]

analysis_only_library = rule(
    implementation = _analysis_only_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "deps": attr.label_list(providers = [DartInfo]),
        "engine": attr.label(providers = [DartInfo], mandatory = True),
    } | package_identity_attrs() | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)

def _undeclared_library_impl(ctx):
    package = library_package(ctx, ctx.files.srcs)
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        dart_info(ctx = ctx, packages = [package.record], srcs = ctx.files.srcs),
    ]

undeclared_library = rule(
    implementation = _undeclared_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
    } | package_identity_attrs(),
)
