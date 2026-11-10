"""The package graph a `pub.from_lock()` library is planned from."""

def _reach(graph, start):
    """Every node reachable from `start` along `graph`'s edges, `start` included."""
    seen = {start: True}
    queue = [start]

    # Starlark has no `while`; each node is queued at most once.
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
    """The packages that depend on `package` and on which it depends: its dependency cycle.

    Pub allows a cycle (`dio` and `dio_web_adapter` each depend on the other);
    Bazel does not, so the packages of one are built as one library.

    Args:
      graph: Dict of package name to the names it depends on. Must hold every
        package reachable from `package`; edges to names absent from it are
        ignored.
      package: The package whose cycle is wanted.

    Returns:
      The sorted names of the cycle's packages: `[package]` when it is in none.
    """
    forward = _reach(graph, package)
    reverse = {}
    for node in forward:
        for dep in graph.get(node, []):
            if dep in forward:
                reverse.setdefault(dep, []).append(node)
    backward = _reach(reverse, package)
    return sorted([node for node in forward if node in backward])
