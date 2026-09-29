"""Rules shaped like `flutter_library` and like a web bundle: their files are
their package's `lib/`.

It returns `DartAnalyzableInfo` whose `srcs` are empty — nothing outside `lib/`
— and lists its files in `DefaultInfo`, which is where the `dart_analyze`
aspect finds a library's own files.
"""

load("@rules_dart//dart:utils.bzl", "dart_analyzable_info_with_package")

def _package_only_library_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        dart_analyzable_info_with_package(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            package_srcs = ctx.files.srcs,
            language_version = "",
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
    # package's `lib/` files reach the aspect only through `package_srcs`.
    bundle = ctx.actions.declare_file(ctx.label.name + ".bundle")
    ctx.actions.write(bundle, "built\n")
    return [
        DefaultInfo(files = depset([bundle])),
        dart_analyzable_info_with_package(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            package_srcs = ctx.files.srcs,
            language_version = "",
        ),
    ]

bundle_shaped = rule(
    implementation = _bundle_shaped_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "package_name": attr.string(mandatory = True),
    },
)
