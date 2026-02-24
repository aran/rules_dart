"""Module extension for declaring pub.dev package dependencies."""

load("//dart/pub/private:pub_lock_repository.bzl", "pub_lock_repository")
load("//dart/pub/private:pub_repository.bzl", "pub_package")

_package = tag_class(
    attrs = {
        "name": attr.string(
            doc = "The pub.dev package name (also used as the repository name).",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive.",
            mandatory = True,
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
    },
)

_from_lock = tag_class(
    attrs = {
        "name": attr.string(
            doc = "Repository name for the resolved packages.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
    },
)

def _pub_impl(ctx):
    # Handle individual package declarations
    packages = {}
    for mod in ctx.modules:
        for pkg in mod.tags.package:
            if pkg.name not in packages:
                packages[pkg.name] = pkg

    for name, pkg in packages.items():
        pub_package(
            name = name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = pkg.deps,
        )

    # Handle lock file declarations
    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            pub_lock_repository(
                name = lock_tag.name,
                lock_file = lock_tag.lock,
            )

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
    },
    doc = "Declares pub.dev package dependencies for download and use as dart_library targets.",
)
