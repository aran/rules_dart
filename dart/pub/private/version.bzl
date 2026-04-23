"""Semantic version parsing and comparison for pub packages."""

# Sentinel prepended to the prerelease segment list. `1` beats `0` so stable
# versions (which carry `(1,)`) sort after their prerelease counterparts.
_STABLE_SENTINEL = (1,)
_PRERELEASE_SENTINEL = (0,)

# Prerelease segments always parse as 3-tuples: (is_string_flag, int_value,
# string_value). Numeric segments are `(0, N, "")`; identifier segments
# are `(1, 0, ID)`. Per semver, numeric < identifier; within each kind,
# natural ordering applies.
_EMPTY_PRE = ()

def parse_semver(version):
    """Parses a semver string into a comparable tuple.

    Follows semver spec: major.minor.patch[-prerelease][+buildmeta].
    A version without prerelease is greater than the same version with one
    (e.g., `1.0.0` > `1.0.0-dev.1`). Build metadata (`+N` / `+sha.123`) is
    stripped before comparison, matching semver precedence rules.

    Both the stable and prerelease paths return a 5-tuple:

        (major, minor, patch, kind_sentinel, prerelease_segments)

    where `kind_sentinel` is `(1,)` for stable versions and `(0,)` for
    prereleases, and `prerelease_segments` is a (possibly empty) tuple of
    3-tuples encoding each prerelease segment. This shape comparison is
    consistent regardless of whether either operand has a prerelease, so
    `semver_gt("1.0.0", "1.0.0-dev.1")` returns cleanly without raising a
    type mismatch.

    Args:
        version: A semver string like `1.9.1`, `2.0.0-dev.1`, or `3.0.0+4`.

    Returns:
        A tuple that can be compared with `>`, `<`, or `==` to other
        `parse_semver` results.
    """
    release, _, pre = version.partition("-")

    # Build metadata is ignored for precedence; strip before parsing.
    release, _, _ = release.partition("+")
    parts = release.split(".")
    nums = tuple([int(p) for p in parts])

    if not pre:
        return nums + (_STABLE_SENTINEL, _EMPTY_PRE)

    pre_segments = []
    for seg in pre.split("."):
        if seg.isdigit():
            pre_segments.append((0, int(seg), ""))
        else:
            pre_segments.append((1, 0, seg))
    return nums + (_PRERELEASE_SENTINEL, tuple(pre_segments))

def semver_gt(a, b):
    """Returns True if semver string a is greater than semver string b."""
    return parse_semver(a) > parse_semver(b)
