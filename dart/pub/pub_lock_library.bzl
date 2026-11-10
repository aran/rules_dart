"""Repository rule for a `pub.from_lock()` package's library.

A locked package's files are in its source repository (`pub_lock_package`);
this one decides what it is built with. It reads the pubspec dependencies of
every package the package reaches, as their source repositories record them,
which fetches only what building the package fetches anyway, and finds its
dependency cycle (`pub_graph.bzl`):
pub allows packages to depend on each other (`dio` and `dio_web_adapter`), and
Bazel does not. The cycle is one `pub_library` in the library repository of its
first package by name, and every other package of it aliases that.

The source repositories read nothing of each other, so planning a cycle never
asks a repository to wait on itself.
"""

load("//dart/pub:pub_graph.bzl", "dependency_cycle", "dependency_graph", "read_pubspec_dependencies")
load("//dart/pub/private:build_content.bzl", "make_pub_library_build_content")

def source_repo(prefix, package):
    return "{}__{}".format(prefix, package)

def library_repo(prefix, package):
    return "{}_lib__{}".format(prefix, package)

def index_repo(prefix):
    return "{}_index".format(prefix)

_INDEX = "index.json"

def unsupplied_dependency_error(package, version, dep, why):
    """The error for a fetched package depending on a locked package nothing fetches.

    Args:
      package: The package with the dependency.
      version: Its version.
      dep: The package it depends on.
      why: How the lock lists `dep`, e.g. "a `sdk` package in @//:pubspec.lock".

    Returns:
      The message.
    """
    return (
        "pub.from_lock(): `{package}` {version} depends on `{dep}`, which is {why}. " +
        "`pub.from_lock()` fetches only hosted and git packages, so nothing supplies `{dep}`, " +
        "and `{package}` would be built without it. Map it to a target that builds it, " +
        "with `resolve = {{\"{dep}\": ...}}` on the `pub.from_lock()` that lists it, or " +
        "declare it with `pub.package(name = \"{dep}\", version = ..., sha256 = ...)`. " +
        "Flutter SDK packages come from rules_flutter's pub extension."
    ).format(package = package, version = version, dep = dep, why = why)

def _read_index(ctx):
    # Through the canonical name, as `read_pubspec_dependencies` reads.
    prefix = ctx.name[:len(ctx.name) - len(ctx.original_name)]
    return json.decode(ctx.read(Label("@@{}{}//:{}".format(prefix, index_repo(ctx.attr.spoke_prefix), _INDEX))))

def _pub_lock_library_impl(ctx):
    prefix = ctx.attr.spoke_prefix
    index = _read_index(ctx)
    fetched = index["versions"]
    explicit = {p: True for p in index["explicit"]}
    resolved = {p: True for p in index["resolved"]}
    unsupplied = index["unsupplied"]
    known = fetched | explicit | resolved | unsupplied

    # Every package this one reaches through fetched packages. A package
    # declared with `pub.package()` is its own repository, whose dependencies
    # the declaration states, and one `resolve` maps is a workspace target,
    # whose dependencies its BUILD file states, so the walk stops at both.
    graph = dependency_graph(
        ctx.attr.package_name,
        lambda p: [d for d in read_pubspec_dependencies(ctx, source_repo(prefix, p)) if d in known],
        follow = fetched,
    )

    cycle = dependency_cycle(graph, ctx.attr.package_name)
    if cycle.owner != ctx.attr.package_name:
        ctx.file("BUILD.bazel", make_pub_library_build_content(
            name = ctx.attr.package_name,
            owner = "@{repo}//:{name}".format(repo = library_repo(prefix, cycle.owner), name = cycle.owner),
        ))
        return ctx.repo_metadata(reproducible = True)

    for member in cycle.packages:
        for dep in graph[member]:
            if dep in unsupplied:
                fail(unsupplied_dependency_error(member, fetched[member], dep, unsupplied[dep]))
    deps = [
        "@{dep}//:{dep}".format(dep = dep) if dep in explicit else "@{repo}//:{dep}".format(repo = library_repo(prefix, dep), dep = dep)
        for dep in cycle.deps
    ]

    ctx.file("BUILD.bazel", make_pub_library_build_content(
        name = ctx.attr.package_name,
        members = ["@{repo}//:{name}".format(repo = source_repo(prefix, m), name = m) for m in cycle.packages],
        deps = sorted(deps),
    ))
    return ctx.repo_metadata(reproducible = True)

pub_lock_library = repository_rule(
    implementation = _pub_lock_library_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The package."),
        "spoke_prefix": attr.string(mandatory = True, doc = "Prefix of the source, library and index repositories' names."),
    },
    doc = "Plans a `pub.from_lock()` package's library: its dependency cycle, built as one target.",
)

def _pub_lock_index_impl(ctx):
    ctx.file("BUILD.bazel", "")
    ctx.file(_INDEX, json.encode({
        "versions": ctx.attr.versions,
        "explicit": ctx.attr.explicit_packages,
        "resolved": ctx.attr.resolved_packages,
        "unsupplied": ctx.attr.unsupplied,
    }))
    return ctx.repo_metadata(reproducible = True)

# What every library repository plans against, stated once rather than on
# each of them: the lock records each repository's attributes, so a list of
# every package on every library repository would grow it by the square of
# the package count.
pub_lock_index = repository_rule(
    implementation = _pub_lock_index_impl,
    attrs = {
        "versions": attr.string_dict(doc = "Every package with a source repository, with its version."),
        "explicit_packages": attr.string_list(doc = "Packages declared with `pub.package()`: a dependency on one is on its own repository."),
        "resolved_packages": attr.string_list(doc = "Packages `resolve` maps to a workspace target: a dependency on one is on its library repository, which passes the target on."),
        "unsupplied": attr.string_dict(doc = "Packages a lock lists that nothing fetches, each with how the lock lists it. Depending on one is an error."),
    },
    doc = "The packages every `pub_lock_library` of one extension plans against.",
)

def _pub_lock_resolved_impl(ctx):
    ctx.file("BUILD.bazel", """\
load("@rules_dart//dart/pub/private:pub_resolved_package.bzl", "pub_resolved_package")

pub_resolved_package(
    name = "{name}",
    package_name = "{name}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)
""".format(name = ctx.attr.package_name, actual = ctx.attr.actual))
    return ctx.repo_metadata(reproducible = True)

# The library repository of a package `resolve` maps, where every library
# repository depending on the package already looks for it.
pub_lock_resolved = repository_rule(
    implementation = _pub_lock_resolved_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The package."),
        "actual": attr.string(mandatory = True, doc = "The canonical label of the workspace target serving it."),
    },
    doc = "A `pub.from_lock()` package's library, served by the workspace target `resolve` maps it to.",
)

def _pub_lock_ignored_impl(ctx):
    ctx.file("BUILD.bazel", """\
load("@rules_dart//dart/pub/private:pub_ignored_package.bzl", "pub_ignored_package")

pub_ignored_package(
    name = {name},
    package_name = {name},
    lock = {lock},
    reason = {reason},
    visibility = ["//visibility:public"],
)
""".format(
        name = json.encode(ctx.attr.package_name),
        lock = json.encode(ctx.attr.lock),
        reason = json.encode(ctx.attr.reason),
    ))
    return ctx.repo_metadata(reproducible = True)

# The library repository of a `path` package `ignored` names, where every
# library repository depending on the package already looks for it.
pub_lock_ignored = repository_rule(
    implementation = _pub_lock_ignored_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The package."),
        "lock": attr.string(mandatory = True, doc = "The lock that names it ignored."),
        "reason": attr.string(mandatory = True, doc = "Why, as the user wrote it."),
    },
    doc = "A `pub.from_lock()` package's library that fails analysis, giving why it is ignored.",
)
