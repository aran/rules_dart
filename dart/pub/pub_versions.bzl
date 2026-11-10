"""The one policy for which version of a hosted pub package a build uses.

Every statement of a package's version is a request: a `pub.package()` in any
module, and each lock that lists the package as hosted. The highest request
wins, as Bazel's minimal version selection picks the highest version any
module asks for. A request is a minimum, so raising a dependency's request is
what it asks for and says nothing. Raising one of the root module's own
requests is reported, at the level the root sets, as Bazel's
`--check_direct_dependencies` reports a raised `bazel_dep` of the root.

The function is pure and returns messages instead of calling `fail`, so a unit
test can check them, and so rules_flutter's pub extension applies the same
policy with its own commands.
"""

load("//dart/pub/private:version.bzl", "parse_semver")

CHECK_LEVELS = ["off", "warning", "error"]

def pub_version_request(version, sha256, url, is_root, where, upgrade = "", refresh = ""):
    """One statement of a hosted package's version, for `select_pub_version`.

    Args:
        version: The version it asks for.
        sha256: The digest it pins for that version's archive.
        url: The registry it fetches from (`https://pub.dev` for pub.dev).
        is_root: Whether the root module states it.
        where: How a message names the statement, as a phrase:
            "`pub.package()` in module `dep`", "the lock `//app:pubspec.lock`".
        upgrade: The command that moves the statement forward, for a lock (a
            `pub upgrade` of the package); empty for a declaration, which the
            message says to edit.
        refresh: The command that rewrites the statement's digest, for a lock
            (a `pub get`); empty for a declaration.

    Returns:
        The request.
    """
    return struct(
        version = version,
        sha256 = sha256,
        url = url,
        is_root = is_root,
        where = where,
        upgrade = upgrade,
        refresh = refresh,
    )

def _line(request):
    return "  - %s, from %s" % (request.version, request.where)

def _raise_fix(request, winner):
    if request.upgrade:
        return "  %s" % request.upgrade
    return "  set %s to version = \"%s\", sha256 = \"%s\"" % (request.where, winner.version, winner.sha256)

def select_pub_version(name, requests, check_direct_dependencies = "warning", settings = "pub.settings"):
    """Decides which version of a hosted package the build uses.

    Args:
        name: The package's name.
        requests: Every `pub_version_request` for it, in a stable order; the
            first at the highest version is the one returned.
        check_direct_dependencies: The root's level for its own raised
            requests: `off`, `warning` (the default) or `error`.
        settings: The tag the root sets that level with, as a message names it.

    Returns:
        `struct(request, warning, error)`: the winning request (None when
        `error` is set), and the messages, each None when there is none.
        `error` is set when two requests disagree on the registry or on a
        version's digest, or when a root request is raised and the level is
        `error`; `warning`, when one is raised and the level is `warning`.
    """
    if check_direct_dependencies not in CHECK_LEVELS:
        fail("check_direct_dependencies must be one of %s, not %r" % (CHECK_LEVELS, check_direct_dependencies))
    first = requests[0]
    for r in requests[1:]:
        if r.url != first.url:
            return struct(request = None, warning = None, error = (
                "Package \"%s\" is fetched from different registries:\n" +
                "  - %s, from %s\n" +
                "  - %s, from %s\n" +
                "The build has one copy of each package; make them agree."
            ) % (name, first.url, first.where, r.url, r.where))

    by_version = {}
    for r in requests:
        other = by_version.setdefault(r.version, r)
        if other.sha256 != r.sha256:
            fixes = {x.refresh: True for x in (other, r) if x.refresh}.keys()
            hints = []
            if fixes:
                hints.append(
                    "Re-resolving a lock checks its digests against the registry and reports " +
                    "a wrong one. Run each from the root of the workspace that holds that lock:\n" +
                    "\n".join(["  " + f for f in fixes]),
                )
            if len(fixes) < 2:
                hints.append("A declaration takes the digest the registry's API gives for the version.")
            return struct(request = None, warning = None, error = (
                "Package \"%s\" %s has conflicting sha256 digests:\n" +
                "  - %s, from %s\n" +
                "  - %s, from %s\n" +
                "At most one of them describes the archive the registry serves.\n%s"
            ) % (name, r.version, other.sha256, other.where, r.sha256, r.where, "\n".join(hints)))

    winner = first
    for r in requests[1:]:
        if parse_semver(r.version) > parse_semver(winner.version):
            winner = r

    raised = [r for r in requests if r.is_root and r.version != winner.version]
    if not raised or check_direct_dependencies == "off":
        return struct(request = winner, warning = None, error = None)
    message = (
        "Package \"%s\" is built at %s, newer than the root module asks for:\n%s\n" +
        "Raised by:\n%s\n" +
        "Each request is a minimum and the highest wins. Raise the root's to %s:\n%s\n" +
        "or set `%s(check_direct_dependencies = \"off\")` in the root module to stop this check."
    ) % (
        name,
        winner.version,
        "\n".join([_line(r) for r in raised]),
        "\n".join([_line(r) for r in requests if r.version == winner.version]),
        winner.version,
        "\n".join([_raise_fix(r, winner) for r in raised]),
        settings,
    )
    if check_direct_dependencies == "error":
        return struct(request = None, warning = None, error = message)
    return struct(request = winner, warning = message, error = None)
