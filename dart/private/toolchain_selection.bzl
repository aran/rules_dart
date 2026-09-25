"""Picks one Dart SDK version per toolchain name from the versions modules request."""

def _parse_version(v):
    """Splits a version string into a list of ints for comparison."""
    return [int(x) for x in v.split(".")]

def select_toolchain_version(name, requests):
    """Selects the latest requested version for one toolchain name.

    Args:
      name: The toolchain name, used in the note.
      requests: Non-empty list of `struct(version, is_root)`, one per tag.

    Returns:
      `struct(version, note)`. `note` is a message for the user when the root
      module requested a version that was not selected, and None otherwise:
      a dependency asking for an older SDK than the one in use is not news.
    """
    selected = requests[0].version
    for request in requests[1:]:
        if _parse_version(request.version) > _parse_version(selected):
            selected = request.version

    root_versions = [r.version for r in requests if r.is_root]
    note = None
    if root_versions and selected not in root_versions:
        note = "Dart toolchain {} uses {}, not {} requested by the root module, because a dependency requires it".format(
            name,
            selected,
            " or ".join(root_versions),
        )
    return struct(version = selected, note = note)
