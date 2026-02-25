"""Repository rule that downloads all packages from a pubspec.lock file.

Downloads each hosted package, reads its pubspec.yaml to determine
inter-package dependencies, and generates BUILD files with correct dep graphs.
"""

load("//dart/pub/private:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_lock")

def _pub_lock_repository_impl(ctx):
    # Read and parse the lock file
    lock_path = ctx.path(ctx.attr.lock_file)
    lock_content = ctx.read(lock_path)
    packages = parse_pubspec_lock(lock_content)

    # Filter to only hosted packages, warn about unsupported sources
    hosted_packages = {}
    for name, info in packages.items():
        source = info.get("source", "unknown")
        if source == "hosted":
            hosted_packages[name] = info
        elif source == "sdk":
            # SDK packages (e.g. dart itself) are provided by the toolchain
            pass
        else:
            # buildifier: disable=print
            print("pub.from_lock: skipping package \"%s\" (source: %s). Only hosted packages are supported." % (name, source))  # noqa: E501

    if not hosted_packages:
        # No hosted packages - create empty repo
        ctx.file("BUILD.bazel", "# No hosted packages found in lock file\n")
        return

    # Download each hosted package
    for name, info in hosted_packages.items():
        desc = info.get("description", {})
        version = info.get("version", "")
        sha256 = desc.get("sha256", "")
        base_url = desc.get("url", "https://pub.dev")

        url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
            base = base_url,
            name = name,
            version = version,
        )

        ctx.download_and_extract(
            url = url,
            sha256 = sha256,
            output = name,
            type = "tar.gz",
        )

    # Read each package's pubspec.yaml to find dependencies
    package_deps = {}
    for name in hosted_packages:
        pubspec_path = ctx.path(name + "/pubspec.yaml")
        if pubspec_path.exists:
            pubspec_content = ctx.read(pubspec_path)
            all_deps = parse_pubspec_deps(pubspec_content)
            # Filter to only deps that are in our hosted packages set
            bazel_deps = [dep for dep in all_deps if dep in hosted_packages]
            package_deps[name] = bazel_deps
        else:
            package_deps[name] = []

    # Generate BUILD file for each package
    for name in hosted_packages:
        deps = package_deps.get(name, [])
        dep_labels = ['        "//:{dep}",'.format(dep = dep) for dep in deps]
        deps_block = ""
        if dep_labels:
            deps_block = "    deps = [\n{deps}\n    ],\n".format(
                deps = "\n".join(dep_labels),
            )

        build_content = """\
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
{deps}    package_name = "{name}",
    visibility = ["//visibility:public"],
)
""".format(
            name = name,
            deps = deps_block,
        )

        ctx.file(name + "/BUILD.bazel", build_content)

    # Generate root BUILD file that re-exports all packages as aliases
    alias_entries = []
    for name in sorted(hosted_packages.keys()):
        alias_entries.append("""\
alias(
    name = "{name}",
    actual = "//{name}",
    visibility = ["//visibility:public"],
)
""".format(name = name))

    root_build = "\n".join(alias_entries)
    ctx.file("BUILD.bazel", root_build)

pub_lock_repository = repository_rule(
    implementation = _pub_lock_repository_impl,
    attrs = {
        "lock_file": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
    },
    doc = "Downloads all hosted packages from a pubspec.lock file and generates BUILD files.",
)
