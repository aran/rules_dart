"""Rules shaped like `flutter_library` and like a web bundle: their files are
their package's `lib/`.

It returns `DartAnalyzableInfo` whose `entry_srcs` are empty — nothing outside `lib/`
— and lists its files in `DefaultInfo`, which is where the `dart_analyze`
aspect finds a library's own files.
"""

load("@rules_dart//dart:providers.bzl", "DartPackageInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info")

def _package_only_library_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        dart_analyzable_info(
            label = ctx.label,
            packages = [DartPackageInfo(
                label = ctx.label,
                package_name = ctx.attr.package_name,
                package_root = ctx.label.package,
                language_version = "",
            )],
            srcs = ctx.files.srcs,
        ),
    ]

package_only_library = rule(
    implementation = _package_only_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "package_name": attr.string(mandatory = True),
    },
)

def _bundle_shaped_impl(ctx):
    # A bundle's `DefaultInfo` is the built artifact, not its sources, so the
    # package's `lib/` files reach the aspect only through `srcs`.
    bundle = ctx.actions.declare_file(ctx.label.name + ".bundle")
    ctx.actions.write(bundle, "built\n")
    return [
        DefaultInfo(files = depset([bundle])),
        dart_analyzable_info(
            label = ctx.label,
            packages = [DartPackageInfo(
                label = ctx.label,
                package_name = ctx.attr.package_name,
                package_root = ctx.label.package,
                language_version = "",
            )],
            srcs = ctx.files.srcs,
        ),
    ]

bundle_shaped = rule(
    implementation = _bundle_shaped_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "package_name": attr.string(mandatory = True),
    },
)
