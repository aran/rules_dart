"""Version parsing, ordering and constraints for pub packages, as pub_semver has them."""

visibility("//dart/...")

# The pre-release slot of a key: a release, `(1,)`, sorts after any
# pre-release of it, `(0,)`.
_STABLE = (1,)
_PRERELEASE = (0,)

_IDENTIFIER_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"
_DIGITS = "0123456789"
_MAX_INT64 = "9223372036854775807"

# What Dart's `String.trim` removes, each as Bazel holds it: a string is its
# UTF-8 bytes, one character each. Starlark's own `strip` differs: it also
# removes U+001C to U+001F, and only the last byte of U+00A0.
_WHITESPACE = (
    " ",
    "\t",
    "\n",
    "\013",
    "\f",
    "\r",
    "\302\205",  # U+0085
    "\302\240",  # U+00A0
    "\341\232\200",  # U+1680
    "\342\200\200",  # U+2000 to U+200A
    "\342\200\201",
    "\342\200\202",
    "\342\200\203",
    "\342\200\204",
    "\342\200\205",
    "\342\200\206",
    "\342\200\207",
    "\342\200\210",
    "\342\200\211",
    "\342\200\212",
    "\342\200\250",  # U+2028
    "\342\200\251",  # U+2029
    "\342\200\257",  # U+202F
    "\342\201\237",  # U+205F
    "\343\200\200",  # U+3000
    "\357\273\277",  # U+FEFF
)

def _number(text):
    # pub_semver reads `01` as 1; Starlark's int() refuses a leading zero.
    return int(text.lstrip("0") or "0")

def _fits_int64(digits):
    """Whether Dart's `int.parse` can hold `digits`."""
    significant = digits.lstrip("0")
    if len(significant) != len(_MAX_INT64):
        return len(significant) < len(_MAX_INT64)
    return significant <= _MAX_INT64

def _parts(text):
    """Splits a pre-release or build string into comparable parts, or None if malformed."""
    parts = []
    for part in text.split("."):
        if not part or part.strip(_IDENTIFIER_CHARS):
            return None

        # A numeric part sorts before an identifier, and numbers by value. One
        # too long for an int is an identifier to pub_semver.
        parts.append((0, _number(part), "") if part.isdigit() and _fits_int64(part) else (1, 0, part))
    return tuple(parts)

def _split(version):
    """The release numbers and the pre-release and build parts, or None where pub_semver could not parse it."""
    rest, has_build, build = version.partition("+")
    release, has_pre, pre = rest.partition("-")
    numbers = release.split(".")
    pre_parts = _parts(pre) if has_pre else ()
    build_parts = _parts(build) if has_build else ()
    if (len(numbers) != 3 or not all([n.isdigit() and _fits_int64(n) for n in numbers]) or
        pre_parts == None or build_parts == None):
        return None
    return struct(numbers = numbers, has_pre = has_pre, pre = pre_parts, build = build_parts)

def is_semver(version):
    """Whether pub_semver parses `version`: `major.minor.patch[-prerelease][+build]`.

    Args:
        version: The text.

    Returns:
        A bool.
    """
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
        if end == at or not _fits_int64(text[at:end]):
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

def _leading_whitespace(text):
    for space in _WHITESPACE:
        if text.startswith(space):
            return len(space)
    return 0

def _trailing_whitespace(text):
    for space in _WHITESPACE:
        if text.endswith(space):
            return len(space)
    return 0

def _trim(text):
    """`text` as Dart's `String.trim` leaves it."""
    for _ in range(len(text)):
        length = _leading_whitespace(text)
        if not length:
            break
        text = text[length:]
    for _ in range(len(text)):
        length = _trailing_whitespace(text)
        if not length:
            break
        text = text[:-length]
    return text

def _is_prerelease(key):
    return key[3] == _PRERELEASE

def _first_prerelease(key):
    """The key of `<major>.<minor>.<patch>-0`, pub_semver's `firstPreRelease`."""
    return key[:3] + (_PRERELEASE, ((0, 0, ""),), ())

def _constraint(error = None, empty = False, lower = None, include_lower = False, upper = None, include_upper = False):
    return struct(
        error = error,
        empty = empty,
        lower = lower,
        include_lower = include_lower,
        upper = upper,
        include_upper = include_upper,
    )

def _compatible_with(key):
    """`^version`: from it up to the first pre-release of its next breaking version."""
    major, minor = key[0], key[1]

    # pub_semver's addition overflows, and its `Version` refuses the result.
    if str(major if major else minor) == _MAX_INT64:
        return _constraint(error = "the next breaking version is too large")
    upper = (0, minor + 1, 0) if major == 0 else (major + 1, 0, 0)
    return _constraint(lower = key, include_lower = True, upper = _first_prerelease(upper))

def parse_constraint(text):
    """Reads a version constraint as pub_semver's `VersionConstraint.parse` does.

    It takes `any`, `^` and a version, or one or more of a version or a
    comparison (`<`, `<=`, `>`, `>=`) and a version, split by any whitespace
    or none, in whatever order and count. Surrounding whitespace is ignored.

    Args:
        text: A constraint, such as `>=3.0.0 <4.0.0`.

    Returns:
        What `constraint_allows_key` takes: a struct whose `error` says why
        pub_semver refuses `text`, or is None.
    """
    rest = _trim(text)
    if rest == "any":
        return _constraint()
    if rest.startswith("^"):
        rest = _trim(rest[1:])
        after = _after_version(rest)
        if after == None:
            return _constraint(error = "expected a version number after \"^\", got {}".format(repr(rest)))
        if after:
            return _constraint(error = "cannot include other constraints with \"^\"")
        return _compatible_with(parse_semver(rest))

    lower = None
    include_lower = False
    upper = None
    include_upper = False
    for _ in range(len(rest) + 1):
        rest = _trim(rest)
        if not rest:
            break
        after = _after_version(rest)
        if after != None:
            # A bare version is both bounds, inclusive.
            operator = ""
        else:
            operator = rest[:2] if rest[:2] in ("<=", ">=") else rest[:1]
            if operator not in ("<", "<=", ">", ">="):
                return _constraint(error = "unknown text at {}".format(repr(rest)))
            rest = _trim(rest[len(operator):])
            after = _after_version(rest)
            if after == None:
                return _constraint(error = "expected a version number after \"{}\", got {}".format(operator, repr(rest)))
        version = parse_semver(rest[:len(rest) - len(after)])
        rest = after

        # Each bound narrows the range, and of two at one version the
        # exclusive one holds.
        if operator in ("", ">", ">="):
            inclusive = operator != ">"
            if lower == None or version > lower:
                lower = version
                include_lower = inclusive
            elif version == lower and not inclusive:
                include_lower = False
        if operator in ("", "<", "<="):
            inclusive = operator != "<"
            if upper == None or version < upper:
                upper = version
                include_upper = inclusive
            elif version == upper and not inclusive:
                include_upper = False

    if lower == None and upper == None:
        return _constraint(error = "cannot parse an empty string")
    if lower != None and upper != None:
        if lower > upper or (lower == upper and not (include_lower and include_upper)):
            return _constraint(empty = True)

    # `<2.0.0` leaves out 2.0.0's pre-releases, unless the range starts among
    # them or the bound is itself a pre-release or has a build.
    if (upper != None and not include_upper and not _is_prerelease(upper) and not upper[5] and
        (lower == None or not _is_prerelease(lower) or lower[:3] != upper[:3])):
        upper = _first_prerelease(upper)
    return _constraint(lower = lower, include_lower = include_lower, upper = upper, include_upper = include_upper)

def constraint_error(text):
    """Says why pub_semver's `VersionConstraint.parse` refuses `text`.

    Args:
        text: A constraint, such as `>=3.0.0 <4.0.0`.

    Returns:
        A description of the problem, or None for a constraint pub reads.
    """
    return parse_constraint(text).error

def constraint_allows_key(constraint, key):
    """Whether a parsed constraint allows a version, as pub_semver's `allows` does.

    Args:
        constraint: `parse_constraint`'s result, with no `error`.
        key: The version's `parse_semver` key.

    Returns:
        A bool.
    """
    if constraint.empty:
        return False
    if constraint.lower != None:
        if key < constraint.lower or (key == constraint.lower and not constraint.include_lower):
            return False
    if constraint.upper != None:
        if key > constraint.upper or (key == constraint.upper and not constraint.include_upper):
            return False
    return True

def constraint_allows(constraint, version):
    """Whether `VersionConstraint.parse(constraint).allows(version)` holds in pub_semver.

    Args:
        constraint: A constraint, such as `>=3.0.0 <4.0.0`.
        version: A version, such as `3.50.1-0.0.pre-12`.

    Returns:
        A bool. Fails on a constraint or version pub_semver could not parse.
    """
    parsed = parse_constraint(constraint)
    if parsed.error != None:
        fail("Could not parse the version constraint {}: {}.".format(repr(constraint), parsed.error))
    return constraint_allows_key(parsed, parse_semver(version))
