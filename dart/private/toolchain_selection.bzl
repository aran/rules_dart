"""Picks one Dart SDK version per toolchain name from the versions modules request."""

visibility("//dart/...")

def _parse_version(v):
    """Splits a version string into a list of ints for comparison."""
    return [int(x) for x in v.split(".")]

def _newer(a, b):
    return _parse_version(a) > _parse_version(b)

def _failure(error):
    return struct(version = None, error = error)

def select_toolchain_version(name, requests):
    """Selects the Dart SDK version for one toolchain name.

    Every request is a minimum: no rule here gives a module an SDK older than
    the one it requested.

    * With no request from the root module, the highest request wins.
    * With a root request, it is used exactly, and a dependency requesting a
      newer version is an error, unless the root allows the upgrade, in which
      case the highest of all requests wins, the root's included.
    * Two root requests for one name are an error: the root's pin is ambiguous.
    * Only the root module may allow the upgrade.

    Args:
      name: The toolchain name, used in error text.
      requests: Non-empty list of
        `struct(module, version, is_root, allow_upgrade)`, one per tag.

    Returns:
      `struct(version, error)`. `error` is a message for the user when the
      requests cannot be reconciled (and `version` is then None), else None.
    """
    for request in requests:
        if request.allow_upgrade and not request.is_root:
            return _failure("""\
Only the root module may set allow_upgrade_by_dependencies on dart.toolchain, \
but module `{module}` sets it for Dart toolchain "{name}". A dependency cannot \
decide that other modules' SDK pin may be raised; set it in the root module.""".format(
                module = request.module,
                name = name,
            ))

    roots = [r for r in requests if r.is_root]
    dependencies = [r for r in requests if not r.is_root]

    if len(roots) > 1:
        return _failure("""\
The root module requests Dart toolchain "{name}" more than once ({versions}), \
so its pin is ambiguous. A toolchain name takes one root request: keep one \
dart.toolchain(...) tag for it, or give each its own name.""".format(
            name = name,
            versions = ", ".join([r.version for r in roots]),
        ))

    if not roots or roots[0].allow_upgrade:
        selected = requests[0].version
        for request in requests[1:]:
            if _newer(request.version, selected):
                selected = request.version
        return struct(version = selected, error = None)

    pinned = roots[0].version
    newer = [d for d in dependencies if _newer(d.version, pinned)]
    if not newer:
        return struct(version = pinned, error = None)

    highest = newer[0].version
    for request in newer[1:]:
        if _newer(request.version, highest):
            highest = request.version
    return _failure("""\
Dart toolchain "{name}": the root module pins {pinned}, but these modules request a newer Dart SDK:
{requests}
Either raise the root module's dart.toolchain(dart_version = ...) to at least {highest}, \
or set dart.toolchain(allow_upgrade_by_dependencies = True) in the root module \
to let dependencies raise its pin.""".format(
        name = name,
        pinned = pinned,
        requests = "\n".join(["  {} requests {}".format(d.module, d.version) for d in newer]),
        highest = highest,
    ))
