"""Planning a pub package's library: its dependency graph and its cycle.

For repository rules that build pub packages as rules_dart's `pub.from_lock()`
does, in two repositories each (see `pub_library.bzl`). A package's source
repository records the names its pubspec depends on with
`write_pubspec_dependencies()`. Its library repository reads them back, for
every package it reaches, with `read_pubspec_dependencies()`, walking with
`dependency_graph()`, and asks `dependency_cycle()` which packages it is built
with and what they depend on:

    def _my_library_repo_impl(ctx):
        graph = dependency_graph(
            ctx.attr.package_name,
            lambda p: [d for d in read_pubspec_dependencies(ctx, "my_src__" + p) if d in known],
            follow = known,
        )
        cycle = dependency_cycle(graph, ctx.attr.package_name)
        if cycle.owner != ctx.attr.package_name:
            ...  # alias the library in `my_lib__<owner>`
        else:
            ...  # a library over `@my_src__<m>//:<m>` for m in cycle.packages,
                 # depending on `@my_lib__<d>//:<d>` for d in cycle.deps

The source repositories read nothing of each other, so the planning never asks
a repository to wait on itself, and the library repository fetches only the
source repositories building the package fetches anyway.
"""

_PUBSPEC_DEPENDENCIES = "pubspec_dependencies.txt"

def write_pubspec_dependencies(ctx, names):
    """Records, in a package's source repository, the names its pubspec depends on.

    Args:
      ctx: The source repository's `repository_ctx`.
      names: The names under the package's pubspec `dependencies:`, as
        `parse_pubspec_deps` (`yaml_parser.bzl`) reads them.
    """
    ctx.file(_PUBSPEC_DEPENDENCIES, "".join([n + "\n" for n in names]))

def read_pubspec_dependencies(ctx, repo):
    """Reads what `write_pubspec_dependencies()` recorded in another repository.

    The repository is read through its canonical name, not a label attribute:
    Bazel fetches every repository a label attribute names before the rule
    runs, and only the packages reached are wanted.

    Args:
      ctx: The reading repository's `repository_ctx`.
      repo: The source repository's name as the module extension that made
        both gave it. The two must come from the same module extension.

    Returns:
      The recorded names, in order.
    """
    sibling = "@@" + ctx.name[:len(ctx.name) - len(ctx.original_name)] + repo
    return ctx.read(Label("{}//:{}".format(sibling, _PUBSPEC_DEPENDENCIES))).splitlines()

def dependency_graph(package, dependencies, follow):
    """The packages `package` reaches, each with the names it depends on.

    Args:
      package: The package to start from. Its dependencies are always read.
      dependencies: Function of a package name to the names it depends on.
      follow: The packages whose own dependencies are read when reached, as a
        dict or list. The others are leaves: a package declared on its own,
        whose dependencies its declaration states.

    Returns:
      Dict of package name to the names it depends on, for `package` and every
      package of `follow` it reaches.
    """
    graph = {}
    queue = [package]

    # Starlark has no `while`; each package is queued at most once.
    for _ in range(len(follow) + 1):
        if not queue:
            break
        next_queue = []
        for node in queue:
            graph[node] = list(dependencies(node))
            for dep in graph[node]:
                if dep in follow and dep not in graph and dep not in next_queue:
                    next_queue.append(dep)
        queue = next_queue
    return graph

def _reach(graph, start):
    """Every node reachable from `start` along `graph`'s edges, `start` included."""
    seen = {start: True}
    queue = [start]
    for _ in range(len(graph) + 1):
        if not queue:
            break
        next_queue = []
        for node in queue:
            for dep in graph.get(node, []):
                if dep not in seen:
                    seen[dep] = True
                    next_queue.append(dep)
        queue = next_queue
    return seen

def dependency_cycle(graph, package):
    """The dependency cycle `package` is built in, and what the cycle depends on.

    Pub allows a cycle (`dio` and `dio_web_adapter` each depend on the other);
    Bazel does not, so the packages of one are built as one library, in the
    library repository of its `owner`, which every other package of it
    aliases.

    Args:
      graph: Dict of package name to the names it depends on, as
        `dependency_graph()` returns. Must hold every package reachable from
        `package`; edges to names absent from it are leaves.
      package: The package whose cycle is wanted.

    Returns:
      `struct(packages, owner, deps)`: `packages`, the sorted names of the
      packages that depend on `package` and on which it depends (`[package]`
      when it is in no cycle); `owner`, the first of them, whose library
      repository builds the cycle; and `deps`, the sorted names the packages
      depend on outside the cycle.
    """
    forward = _reach(graph, package)
    reverse = {}
    for node in forward:
        for dep in graph.get(node, []):
            if dep in forward:
                reverse.setdefault(dep, []).append(node)
    backward = _reach(reverse, package)
    packages = sorted([node for node in forward if node in backward])
    in_cycle = {p: True for p in packages}
    deps = {dep: True for p in packages for dep in graph.get(p, []) if dep not in in_cycle}
    return struct(
        packages = packages,
        owner = packages[0],
        deps = sorted(deps.keys()),
    )
