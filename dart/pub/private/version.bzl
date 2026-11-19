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

_DIGITS = "0123456789"
_MAX_INT64 = "9223372036854775807"

def _run(text, start, chars):
    """The end of the run of `chars` that begins at `start`."""
    end = start
    for _ in range(start, len(text)):
        if text[end] not in chars:
            break
        end += 1
    return end

def _identifiers(text, start):
    """The end of `ident(.ident)*` at `start`, or `start` where there is none."""
    end = _run(text, start, _IDENTIFIER_CHARS)
    if end == start:
        return start
    for _ in range(len(text)):
        if end >= len(text) or text[end] != ".":
            break
        next_end = _run(text, end + 1, _IDENTIFIER_CHARS)
        if next_end == end + 1:
            break
        end = next_end
    return end

def _after_version(text):
    """What follows the version `text` begins with, or None where it begins with none.

    This is the pattern pub_semver matches at the start of a constraint, so it
    takes a prefix, and refuses a number Dart's `int.parse` cannot hold.
    """
    at = 0
    for part in range(3):
        end = _run(text, at, _DIGITS)
        digits = text[at:end].lstrip("0")
        if end == at or len(digits) > len(_MAX_INT64) or (len(digits) == len(_MAX_INT64) and digits > _MAX_INT64):
            return None
        at = end
        if part < 2:
            if at >= len(text) or text[at] != ".":
                return None
            at += 1
    for lead in ("-", "+"):
        if at < len(text) and text[at] == lead:
            end = _identifiers(text, at + 1)
            if end > at + 1:
                at = end
    return text[at:]

def constraint_error(text):
    """Says why pub_semver's `VersionConstraint.parse` refuses `text`.

    It takes `any`, `^` and a version, or one or more of a version or a
    comparison (`<`, `<=`, `>`, `>=`) and a version, split by any whitespace
    or none, in whatever order and count. Surrounding whitespace is ignored.

    Args:
        text: A constraint, such as `>=3.0.0 <4.0.0`.

    Returns:
        A description of the problem, or None for a constraint pub reads.
    """
    rest = text.strip()
    if rest == "any":
        return None
    if rest.startswith("^"):
        rest = rest[1:].strip()
        after = _after_version(rest)
        if after == None:
            return "expected a version number after \"^\", got {}".format(repr(rest))
        if after:
            return "cannot include other constraints with \"^\""
        return None
    terms = 0
    for _ in range(len(rest) + 1):
        rest = rest.strip()
        if not rest:
            break
        after = _after_version(rest)
        if after == None:
            operator = rest[:2] if rest[:2] in ("<=", ">=") else rest[:1]
            if operator not in ("<", "<=", ">", ">="):
                return "unknown text at {}".format(repr(rest))
            rest = rest[len(operator):].strip()
            after = _after_version(rest)
            if after == None:
                return "expected a version number after \"{}\", got {}".format(operator, repr(rest))
        rest = after
        terms += 1
    if not terms:
        return "cannot parse an empty string"
    return None
