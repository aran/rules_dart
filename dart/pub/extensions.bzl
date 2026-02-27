"""Module extension for declaring pub.dev package dependencies."""

load("//dart/pub/private:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub/private:pub_lock_package.bzl", "pub_lock_package")
load("//dart/pub/private:pub_repository.bzl", "pub_package")
load("//dart/pub/private:yaml_parser.bzl", "parse_pubspec_lock")

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
    # Handle individual package declarations — these take priority
    explicit = {}
    for mod in ctx.modules:
        for pkg in mod.tags.package:
            if pkg.name not in explicit:
                explicit[pkg.name] = pkg

    for name, pkg in explicit.items():
        pub_package(
            name = name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = pkg.deps,
        )

    # Handle lock file declarations — hub + spoke pattern
    all_hub_names = []
    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            hub_name = lock_tag.name
            lock_content = ctx.read(lock_tag.lock)
            lock_pkgs = parse_pubspec_lock(lock_content)

            # Filter to only hosted packages
            hosted = {}
            for name, info in lock_pkgs.items():
                source = info.get("source", "unknown")
                if source == "hosted":
                    hosted[name] = info
                elif source == "sdk":
                    pass
                else:
                    # buildifier: disable=print
                    print("pub.from_lock: skipping package \"%s\" (source: %s). Only hosted packages are supported." % (name, source))  # noqa: E501

            hosted_names = sorted(hosted.keys())

            # Create spoke repo for each hosted package
            for name, info in hosted.items():
                if name in explicit:
                    continue  # pub.package() wins
                desc = info.get("description", {})
                pub_lock_package(
                    name = hub_name + "__" + name,
                    package_name = name,
                    version = info.get("version", ""),
                    sha256 = desc.get("sha256", ""),
                    base_url = desc.get("url", "https://pub.dev"),
                    hub_name = hub_name,
                    lock_packages = hosted_names,
                )

            # Create hub repo with aliases
            pub_lock_hub(
                name = hub_name,
                hub_name = hub_name,
                packages = hosted_names,
            )
            all_hub_names.append(hub_name)

    return ctx.extension_metadata(
        root_module_direct_deps = list(explicit.keys()) + all_hub_names,
        root_module_direct_dev_deps = [],
    )

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
    },
    doc = "Declares pub.dev package dependencies for download and use as dart_library targets.",
)
