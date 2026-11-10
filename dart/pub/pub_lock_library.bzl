"""Repository rule for a `pub.from_lock()` package's library.

A locked package's files are in its source repository (`pub_lock_package`);
this one decides what it is built with. It reads the pubspec dependencies of
every package the package reaches, as their source repositories record them
(`PUBSPEC_DEPENDENCIES`), which fetches
only what building the package fetches anyway, and finds its dependency cycle:
pub allows packages to depend on each other (`dio` and `dio_web_adapter`), and
Bazel does not. The cycle is one `pub_library` in the library repository of its
first package by name, and every other package of it aliases that.

The source repositories read nothing of each other, so planning a cycle never
asks a repository to wait on itself.
"""

load("//dart/pub:pub_lock_package.bzl", "PUBSPEC_DEPENDENCIES")
load("//dart/pub/private:build_content.bzl", "make_pub_library_build_content")
load("//dart/pub/private:pub_graph.bzl", "dependency_cycle")

def source_repo(prefix, package):
    return "{}__{}".format(prefix, package)

def library_repo(prefix, package):
    return "{}_lib__{}".format(prefix, package)

def index_repo(prefix):
    return "{}_index".format(prefix)

_INDEX = "index.json"

def _sibling(ctx, repo):
    # A sibling's canonical name: this repository's, with its own name (as the
    # extension gave it) replaced. Read through the canonical name, not a label
    # attribute, because Bazel fetches every repository a label attribute names
    # before the rule runs, and only the packages reached are wanted.
    return "@@" + ctx.name[:len(ctx.name) - len(ctx.original_name)] + repo

def _read_index(ctx):
    return json.decode(ctx.read(Label("{}//:{}".format(_sibling(ctx, index_repo(ctx.attr.spoke_prefix)), _INDEX))))

def _pubspec_deps(ctx, package, known):
    recorded = ctx.read(Label("{}//:{}".format(_sibling(ctx, source_repo(ctx.attr.spoke_prefix, package)), PUBSPEC_DEPENDENCIES)))
    return [d for d in recorded.splitlines() if d in known]

def _pub_lock_library_impl(ctx):
    prefix = ctx.attr.spoke_prefix
    index = _read_index(ctx)
    fetched = index["versions"]
    explicit = {p: True for p in index["explicit"]}
    known = fetched | explicit

    # Every package this one reaches through fetched packages. A package
    # declared with `pub.package()` is its own repository, whose dependencies
    # the declaration states, so the walk stops there.
    graph = {}
    queue = [ctx.attr.package_name]
    for _ in range(len(fetched) + 1):
        if not queue:
            break
        next_queue = []
        for package in queue:
            graph[package] = _pubspec_deps(ctx, package, known)
            for dep in graph[package]:
                if dep in fetched and dep not in graph and dep not in next_queue:
                    next_queue.append(dep)
        queue = next_queue

    cycle = dependency_cycle(graph, ctx.attr.package_name)
    owner = cycle[0]
    if owner != ctx.attr.package_name:
        ctx.file("BUILD.bazel", make_pub_library_build_content(
            name = ctx.attr.package_name,
            owner = "@{repo}//:{name}".format(repo = library_repo(prefix, owner), name = owner),
        ))
        return ctx.repo_metadata(reproducible = True)

    in_cycle = {p: True for p in cycle}
    deps = {}
    for member in cycle:
        for dep in graph[member]:
            if dep in in_cycle:
                continue
            if dep in explicit:
                deps["@{dep}//:{dep}".format(dep = dep)] = True
            else:
                deps["@{repo}//:{dep}".format(repo = library_repo(prefix, dep), dep = dep)] = True

    ctx.file("BUILD.bazel", make_pub_library_build_content(
        name = ctx.attr.package_name,
        members = ["@{repo}//:{name}".format(repo = source_repo(prefix, m), name = m) for m in cycle],
        deps = sorted(deps.keys()),
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
    },
    doc = "The packages every `pub_lock_library` of one extension plans against.",
)
