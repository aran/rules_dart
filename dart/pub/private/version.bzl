"""Version parsing and ordering for pub packages, as pub_semver orders them."""

visibility("//dart/...")

# The pre-release slot of a key: a release, `(1,)`, sorts after any
# pre-release of it, `(0,)`.
_STABLE = (1,)
_PRERELEASE = (0,)

_IDENTIFIER_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"

def _number(text):
    # pub_semver reads `01` as 1; Starlark's int() refuses a leading zero.
    return int(text.lstrip("0") or "0")

def _parts(text):
    """Splits a pre-release or build string into comparable parts, or None if malformed."""
    parts = []
    for part in text.split("."):
        if not part or part.strip(_IDENTIFIER_CHARS):
            return None

        # A numeric part sorts before an identifier, and numbers by value.
        parts.append((0, _number(part), "") if part.isdigit() else (1, 0, part))
    return tuple(parts)

def _split(version):
    """The release numbers and the pre-release and build parts, or None where pub_semver could not parse it."""
    rest, has_build, build = version.partition("+")
    release, has_pre, pre = rest.partition("-")
    numbers = release.split(".")
    pre_parts = _parts(pre) if has_pre else ()
    build_parts = _parts(build) if has_build else ()
    if (len(numbers) != 3 or not all([n.isdigit() for n in numbers]) or
        pre_parts == None or build_parts == None):
        return None
    return struct(numbers = numbers, has_pre = has_pre, pre = pre_parts, build = build_parts)

def is_semver(version):
    """Whether pub_semver parses `version`: `major.minor.patch[-prerelease][+build]`."""
    return _split(version) != None

def parse_semver(version):
    """Parses a pub version into a key that orders as pub_semver's `Version.compareTo`.

    The form is `major.minor.patch[-prerelease][+build]`, where the
    pre-release ends at the first `+`. A release sorts after its
    pre-releases (`1.0.0-dev.1` < `1.0.0`), and, unlike the semver spec, the
    build is ordered too: no build sorts first, then builds compare part by
    part (`1.0.0` < `1.0.0+1` < `1.0.0+2`). Within a pre-release or build,
    numeric parts compare by value and sort before identifiers, and a list
    sorts after its own prefix.

    Args:
        version: A version string like `1.9.1`, `2.0.0-dev.1`, or `3.0.0+4`.

    Returns:
        A tuple that compares with `>`, `<` and `==` to other `parse_semver`
        results. Fails on a string pub_semver could not parse.
    """
    split = _split(version)
    if split == None:
        fail("Could not parse version \"%s\": pub versions are major.minor.patch[-prerelease][+build]." % version)
    return (
        tuple([_number(n) for n in split.numbers]) +
        (_PRERELEASE if split.has_pre else _STABLE, split.pre, split.build)
    )

def semver_gt(a, b):
    """Returns True if version a orders after version b."""
    return parse_semver(a) > parse_semver(b)
