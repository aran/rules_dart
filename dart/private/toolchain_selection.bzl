"""Picks one Dart SDK version per toolchain name from the versions modules request."""

visibility("//dart/...")

# The oldest Dart SDK rules_dart builds with. Its own tools are compiled by the
# SDK in use, and the `analyzer` package they depend on is written in this
# language version. Raise it when that dependency's language version rises.
MINIMUM_SDK_VERSION = "3.13.0"

_IDENTIFIER_CHARACTERS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

_COMMIT_CHARACTERS = "0123456789abcdef"

def _is_number(text):
    return text.isdigit() and (text == "0" or text[0] != "0")

def _are_identifiers(text):
    return all([
        part and not [c for c in part.elems() if c not in _IDENTIFIER_CHARACTERS]
        for part in text.split(".")
    ])

def parse_version_or_none(v):
    """A sort key for a version, in semver's order: `3.15.0-1.0.dev` < `3.15.0-2.0.beta` < `3.15.0`.

    A version has all three numbers: `3.14` and `3` name no SDK.

    Args:
      v: The version.

    Returns:
      The key, or None when `v` is no version.
    """
    core, plus, build = v.partition("+")
    release, dash, prerelease = core.partition("-")
    numbers = release.split(".")
    if len(numbers) != 3 or not all([_is_number(n) for n in numbers]):
        return None
    if (dash and not _are_identifiers(prerelease)) or (plus and not _are_identifiers(build)):
        return None

    # Numeric identifiers sort below the others, by value.
    identifiers = [
        (0, int(p), "") if p.isdigit() else (1, 0, p)
        for p in prerelease.split(".")
    ] if dash else []
    return ([int(n) for n in numbers], 0 if dash else 1, identifiers)

def edge_commit(version):
    """The commit a main-channel build is of, which its version ends with.

    Args:
      version: The SDK's version.

    Returns:
      The commit for `<release>-edge.<40 hex digits>`, else None.
    """
    parts = version.partition("-")[2].split(".")
    if len(parts) != 2 or parts[0] != "edge" or len(parts[1]) != 40:
        return None
    return parts[1] if not [c for c in parts[1].elems() if c not in _COMMIT_CHARACTERS] else None

def is_published_version(version):
    """Whether the Dart archive names a build this way.

    Args:
      version: The version.

    Returns:
      True for a stable release `3.14.1`, a beta or dev build `3.15.0-1.2.beta`
      or `3.15.0-148.0.dev`, and a main-channel build
      `3.15.0-edge.<commit>`.
    """
    if parse_version_or_none(version) == None or "+" in version:
        return False
    prerelease = version.partition("-")[2]
    if not prerelease:
        return True
    parts = prerelease.split(".")
    if len(parts) == 3 and parts[2] in ("beta", "dev"):
        return _is_number(parts[0]) and _is_number(parts[1])
    return edge_commit(version) != None

# The first Dart SDK whose `dart compile aot-snapshot` for another platform does
# not ask for the target's `dartaotruntime` (dart-lang/sdk 3ebf2405d3c). An
# `aot-snapshot` holds no runtime, but older SDKs fetch one all the same.
_AOT_SNAPSHOT_WITHOUT_RUNTIME = "3.15.0-81.0.dev"

def aot_snapshot_needs_runtime(version):
    """Whether cross-compiling an `aot-snapshot` with this SDK wants the target's runtime.

    Args:
      version: The SDK's version.

    Returns:
      True for SDKs older than `_AOT_SNAPSHOT_WITHOUT_RUNTIME`, and for a
      version that cannot be compared with it: not a version, or a main-channel
      build of that release (`3.15.0-edge.<commit>`), which has no build number
      and may come from either side of the change.
    """
    key = parse_version_or_none(version)
    if key == None:
        return True
    first = parse_version_or_none(_AOT_SNAPSHOT_WITHOUT_RUNTIME)
    if key[0] == first[0] and key[2] and key[2][0][0] == 1:
        return True
    return key < first

def _parse_version(v):
    key = parse_version_or_none(v)
    if key == None:
        fail("`{}` is not a Dart SDK version: expected one like 3.14.1 or 3.15.0-1.2.beta.".format(v))
    return key

def _newer(a, b):
    return _parse_version(a) > _parse_version(b)

def newest_version(versions):
    """The newest of Dart SDK versions, compared numerically, whatever their order.

    Args:
      versions: Version strings, `major.minor.patch`.

    Returns:
      The newest one.
    """
    return sorted(versions, key = _parse_version)[-1]

def unserved_release_error(version, served):
    """What to do about a version rules_dart has no checksums for.

    Args:
      version: The version.
      served: The versions rules_dart serves.

    Returns:
      A message for the user.
    """
    return ("rules_dart does not serve Dart SDK %s. It serves: %s. For another published release, " +
            "declare it with dart.release(name = ..., dart_version = \"%s\", sdk_sha256 = {...}) " +
            "and choose it with dart.use_sdk.") % (version, ", ".join(sorted(served)), version)

def servable_release(selection, served):
    """The release a `dart.toolchain` name is fetched at, and why a build cannot use it, if so.

    Which SDK a build uses is known only once `--@rules_dart//dart:sdk` is, so
    nothing here may stop the extension: what is wrong with an SDK stops the
    builds using it. The repositories are declared at a release rules_dart can
    fetch even then, because the pubspec reader is compiled with `dart`
    whichever SDK builds Dart.

    Args:
      selection: What `select_toolchain_version` returned, without an `error`.
      served: The versions rules_dart serves.

    Returns:
      `struct(version, unavailable)`. `unavailable` is a message for the user,
      or None. A version raised past `served` by a dependency gives none here:
      `sdk_too_old_error` reports it, against the version returned.
    """
    reasons = [selection.conflict] if selection.conflict else []
    version = selection.version
    if version not in served:
        if version == selection.pinned:
            reasons.append(unserved_release_error(version, served))
        version = newest_version(served)
    return struct(version = version, unavailable = "\n".join(reasons) if reasons else None)

def sdk_too_old_error(name, version, requests):
    """Why the SDK `name` cannot serve the modules requesting versions, if it cannot.

    Args:
      name: The SDK's name, as `dart.use_sdk` and the flag name it.
      version: The SDK's version.
      requests: The version each dependency requests at least, by module name.

    Returns:
      A message for the user, or None when the SDK is recent enough for
      rules_dart and for every request.
    """

    # By release number alone: a 3.13.0 prerelease has that language version.
    if _parse_version(version)[0] < _parse_version(MINIMUM_SDK_VERSION)[0]:
        return """\
Dart SDK "{name}" is {version}, but rules_dart needs at least Dart {minimum}: it \
compiles its own tools with the SDK a build uses. Update the SDK "{name}" \
declares, choose another in the root module with dart.use_sdk(name = ...), or \
choose one for this build with --@rules_dart//dart:sdk=<name>.""".format(
            name = name,
            version = version,
            minimum = MINIMUM_SDK_VERSION,
        )
    newer = sorted([module for module, wanted in requests.items() if _newer(wanted, version)])
    if not newer:
        return None
    return """\
Dart SDK "{name}" is {version}, but these modules request a newer Dart SDK:
{requests}
Build with an SDK of at least {highest}: update the SDK "{name}" declares, \
choose another in the root module with dart.use_sdk(name = ...), or choose one \
for this build with --@rules_dart//dart:sdk=<name>.""".format(
        name = name,
        version = version,
        requests = "\n".join(["  {} requests {}".format(m, requests[m]) for m in newer]),
        highest = newest_version([requests[m] for m in newer]),
    )

def named_toolchain_requests(requests, dependency_requests):
    """What `select_toolchain_version` weighs for a toolchain under a name of the root's.

    Only the root module requests such a name, and a dependency's request of the
    default SDK holds for whichever SDK a build uses. So it counts here too, and
    `allow_upgrade_by_dependencies` means the same under every name.

    Args:
      requests: The name's own requests, as `select_toolchain_version` takes them.
      dependency_requests: The version each dependency requests, by module.

    Returns:
      The requests to select among.
    """
    return requests + [
        struct(module = module, version = version, is_root = False, allow_upgrade = False)
        for module, version in sorted(dependency_requests.items())
    ]

def _failure(error):
    return struct(version = None, error = error, conflict = None, pinned = None)

def select_toolchain_version(name, requests, newest):
    """Selects the Dart SDK version for one toolchain name.

    Every request is a minimum: no rule here gives a module an SDK older than
    the one it requested.

    * With no request from the root module, `newest` is used, or a
      dependency's request if it is newer still. A dependency's request is a
      minimum, so it is raised to `newest` without a word.
    * With a root request, it is used exactly, and a dependency requesting a
      newer version is a conflict, unless the root allows the upgrade, in which
      case the highest of all requests wins, the root's included. A conflict
      stops only the builds using this SDK.
    * Two root requests for one name are an error: the root's pin is ambiguous.
    * Only the root module may allow the upgrade.

    Args:
      name: The toolchain name, used in error text.
      requests: List of `struct(module, version, is_root, allow_upgrade)`,
        one per tag; empty when no module requests the name.
      newest: The newest Dart SDK version rules_dart serves.

    Returns:
      `struct(version, error, conflict, pinned)`. `error` is a message for
      the user when the tags themselves cannot stand (and `version` is then
      None), else None. `conflict` is one when a dependency requests more than
      the root's pin, `version` being that pin, else None. `pinned` is the
      version the root requests, or None.
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

    if not roots:
        version = newest_version([newest] + [r.version for r in requests])
        return struct(version = version, error = None, conflict = None, pinned = None)

    pinned = roots[0].version
    if roots[0].allow_upgrade:
        version = newest_version([r.version for r in requests])
        return struct(version = version, error = None, conflict = None, pinned = pinned)

    newer = [d for d in dependencies if _newer(d.version, pinned)]
    if not newer:
        return struct(version = pinned, error = None, conflict = None, pinned = pinned)

    highest = newest_version([d.version for d in newer])
    conflict = """\
Dart toolchain "{name}": the root module pins {pinned}, but these modules request a newer Dart SDK:
{requests}
Raise the root module's dart.toolchain(dart_version = ...) to at least {highest}, \
set dart.toolchain(allow_upgrade_by_dependencies = True) in the root module to \
let dependencies raise its pin, or build with another SDK of at least {highest}: \
dart.use_sdk(name = ...) or --@rules_dart//dart:sdk=<name>.""".format(
        name = name,
        pinned = pinned,
        requests = "\n".join(["  {} requests {}".format(d.module, d.version) for d in newer]),
        highest = highest,
    )
    return struct(version = pinned, error = None, conflict = conflict, pinned = pinned)
