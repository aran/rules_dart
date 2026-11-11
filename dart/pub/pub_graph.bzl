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
            lambda p: read_pubspec_dependencies(ctx, "my_src__" + p),
            follow = known,
        )
        cycle = dependency_cycle(
            graph,
            ctx.attr.package_name,
            declared = root_declarations,
            advisory = other_declarations + curated_cycles(),
            declare = "my_pub.cycle",
        )
        if cycle.owner != ctx.attr.package_name:
            ...  # alias the library in `my_lib__<owner>`
        else:
            ...  # a library over `@my_src__<m>//:<m>` for m in cycle.packages,
                 # depending on `@my_lib__<d>//:<d>` for d in cycle.deps

Packages in a cycle are built as one library only where a declaration says
so; an undeclared cycle fails, naming the declaration to write
(`cycle_declaration()`). The declarations are known before any package is
fetched, so the extension checks their form (`cycle_declarations_error()`);
whether they are cycles is known only here.

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
        `read_pubspec` (`pubspec.bzl`) reads them.
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
        whose own repository plans its dependencies from its pubspec.

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

def _strongly_connected(graph, package):
    """The sorted names of the packages that depend on `package` and on which it depends."""
    forward = _reach(graph, package)
    reverse = {}
    for node in forward:
        for dep in graph.get(node, []):
            if dep in forward:
                reverse.setdefault(dep, []).append(node)
    backward = _reach(reverse, package)
    return sorted([node for node in forward if node in backward])

def _cycle_path(graph, package, members):
    """A shortest way from `package` back to itself through `members`, as `a -> b -> a`."""
    inside = {m: True for m in members}
    came_from = {}
    queue = [package]
    for _ in range(len(members) + 1):
        if not queue or package in came_from:
            break
        next_queue = []
        for node in queue:
            for dep in graph.get(node, []):
                if dep in inside and dep not in came_from:
                    came_from[dep] = node
                    next_queue.append(dep)
        queue = next_queue
    path = [package]
    node = came_from[package]
    for _ in range(len(members)):
        if node == package:
            break
        path.append(node)
        node = came_from[node]
    path.append(package)
    return " -> ".join(reversed(path))

def _names(packages):
    quoted = ["`%s`" % p for p in packages]
    if len(quoted) < 3:
        return " and ".join(quoted)
    return ", ".join(quoted[:-1]) + " and " + quoted[-1]

def cycle_declaration(packages, declare = "pub.cycle"):
    """The declaration that builds `packages` as one library, as a user writes it.

    Args:
      packages: The packages of the cycle.
      declare: The tag that declares a cycle, as `<extension>.<tag>`.

    Returns:
      The declaration, e.g. `pub.cycle(packages = ["dio", "dio_web_adapter"])`.
    """
    return "%s(packages = [%s])" % (declare, ", ".join(['"%s"' % p for p in sorted(packages)]))

def cycle_declarations_error(groups, where, declare = "pub.cycle"):
    """What is wrong with one module's cycle declarations, before any package is fetched.

    A declaration names at least two packages, each once, and no package is in
    two of one module's declarations. Whether the packages are a cycle is
    checked when one of them is planned (`dependency_cycle()`).

    Args:
      groups: The module's declarations, each the list of packages it names.
      where: Who declared them, for the message, e.g. "the root module".
      declare: The tag that declares a cycle, as `<extension>.<tag>`.

    Returns:
      The message, or None when there is nothing wrong.
    """
    problems = []
    first = {}
    for group in groups:
        stated = cycle_declaration(group, declare)
        distinct = {p: True for p in group}
        if len(distinct) != len(group):
            problems.append("  - %s names a package more than once." % stated)
        if len(distinct) < 2:
            problems.append("  - %s names fewer than two packages; a cycle is of several." % stated)
        for p in sorted(distinct):
            if p in first and first[p] != stated:
                problems.append("  - `%s` is in both %s and %s; a package is in one cycle, so declare it as one, with every package in it." % (p, first[p], stated))
            first.setdefault(p, stated)
    if not problems:
        return None
    return "The dependency cycles declared by %s are not well formed:\n%s" % (where, "\n".join(problems))

def _served_cycle_error(graph, package, cycle, served, declare):
    # A package a target of the user's builds is that target, whose deps its
    # BUILD file states. Bazel builds no cycle, and no library holds both that
    # target and pub packages, so no declaration builds a cycle through it.
    mine = [p for p in cycle if p in served]
    if len(mine) == 1:
        built = "%s is built by %s, a target of yours that `resolve` maps it to." % (_names(mine), served[mine[0]])
        it, its = "it", "its"
    else:
        built = "%s are built by targets of yours that `resolve` maps them to (%s)." % (
            _names(mine),
            ", ".join([str(served[p]) for p in mine]),
        )
        it, its = "them", "their"
    return ("Packages %s depend on each other: %s. %s Bazel builds no dependency cycle, " +
            "and a target of yours can't join one with pub packages. To build the cycle, build " +
            "%s as pub packages are built: move %s from `resolve` to `build_from_pubspec` on " +
            "the `pub.from_lock()` that lists %s, depend on %s through that lock's hub, and " +
            "declare the cycle in the root module's MODULE.bazel:\n\n    %s\n\n" +
            "A `BUILD` file under %s `lib/` or `hook/` has to go, since the pub build " +
            "serves those directories.\n") % (
        _names(cycle),
        _cycle_path(graph, package, cycle),
        built,
        _names(mine),
        it,
        it,
        it,
        cycle_declaration(cycle, declare),
        its,
    )

def cycle_error(graph, package, declared = [], advisory = [], declare = "pub.cycle", served = {}):
    """What is wrong with how `package`'s dependency cycle is declared, if anything.

    `dependency_cycle()` fails with this message; it is separate so that it can
    be tested, and so that a caller can see the outcome without failing.

    Args:
      graph: As for `dependency_cycle()`.
      package: As for `dependency_cycle()`.
      declared: As for `dependency_cycle()`.
      advisory: As for `dependency_cycle()`.
      declare: As for `dependency_cycle()`.
      served: As for `dependency_cycle()`.

    Returns:
      The message, or None when the cycle may be planned.
    """
    cycle = _strongly_connected(graph, package)
    if len(cycle) > 1 and [p for p in cycle if p in served]:
        return _served_cycle_error(graph, package, cycle, served, declare)
    for group in declared:
        if package not in group:
            continue
        group = sorted(group)
        if group == cycle:
            return None
        if len(cycle) == 1:
            found = "`%s` is in no cycle" % package
            remedy = "Remove it from the declaration, or remove the declaration."
        else:
            found = "`%s` is in the cycle of %s (%s)" % (package, _names(cycle), _cycle_path(graph, package, cycle))
            remedy = "Declare that cycle instead, with every package in it:\n\n    %s\n" % cycle_declaration(cycle, declare)
        return ("%s, in the root module, is not a dependency cycle at the versions this " +
                "build fetches: %s. %s") % (cycle_declaration(group, declare), found, remedy)
    if len(cycle) == 1 or cycle in [sorted(g) for g in advisory]:
        return None
    return ("Pub packages %s depend on each other: %s. Bazel builds no dependency cycle, so " +
            "packages in one are built as one library, and only where the root module " +
            "declares them, in its MODULE.bazel:\n\n    %s\n") % (
        _names(cycle),
        _cycle_path(graph, package, cycle),
        cycle_declaration(cycle, declare),
    )

def dependency_cycle(graph, package, declared = [], advisory = [], declare = "pub.cycle", served = {}):
    """The dependency cycle `package` is built in, and what the cycle depends on.

    Pub allows a cycle (`dio` and `dio_web_adapter` each depend on the other);
    Bazel does not, so the packages of one are built as one library, in the
    library repository of its `owner`, which every other package of it
    aliases, but only when the cycle is declared. A cycle is declared by the
    root module (`declared`), which must state it exactly, or by a module the
    root depends on or by rules_dart's curated set (`advisory`), whose
    declarations apply where they state it exactly and are inert where they do
    not: a dependency cannot fix what the root's versions made of its
    declaration, and the root can. Fails, naming the packages and the
    declaration to write, when `package` is in an undeclared cycle or in a
    root declaration that is not exactly its cycle, and naming the package to
    build from its pubspec when the cycle passes through one of `served`
    (see `cycle_error()`).

    Args:
      graph: Dict of package name to the names it depends on, as
        `dependency_graph()` returns. Must hold every package reachable from
        `package`; edges to names absent from it are leaves.
      package: The package whose cycle is wanted.
      declared: The root module's cycle declarations, each a list of packages.
      advisory: Every other declaration that may apply: other modules' and
        the curated ones (`curated_cycles()`, `@rules_dart//dart/ext:registry.bzl`).
      declare: The tag that declares a cycle, as `<extension>.<tag>`, for the
        message.
      served: Dict of package name to the target of the user's that builds
        it in place of a library (`pub.from_lock(resolve = ...)`), for the
        packages whose dependencies `graph` holds. No declaration builds a
        cycle through one.

    Returns:
      `struct(packages, owner, deps)`: `packages`, the sorted names of the
      packages that depend on `package` and on which it depends (`[package]`
      when it is in no cycle); `owner`, the first of them, whose library
      repository builds the cycle; and `deps`, the sorted names the packages
      depend on outside the cycle.
    """
    error = cycle_error(graph, package, declared, advisory, declare, served)
    if error:
        fail(error)
    packages = _strongly_connected(graph, package)
    in_cycle = {p: True for p in packages}
    deps = {dep: True for p in packages for dep in graph.get(p, []) if dep not in in_cycle}
    return struct(
        packages = packages,
        owner = packages[0],
        deps = sorted(deps.keys()),
    )
