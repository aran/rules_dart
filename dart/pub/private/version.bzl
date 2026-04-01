"""Semantic version parsing and comparison for pub packages."""

def parse_semver(version):
    """Parses a semver string into a comparable tuple.

    Follows semver spec: major.minor.patch[-prerelease].
    A version without prerelease is greater than the same version with one
    (e.g., 1.0.0 > 1.0.0-dev.1).

    Args:
        version: A semver string like "1.9.1" or "2.0.0-dev.1".

    Returns:
        A tuple that can be compared with > < == to other parse_semver results.
    """
    release, _, pre = version.partition("-")
    parts = release.split(".")
    nums = tuple([int(p) for p in parts])

    # No prerelease > any prerelease. Use (1,) as a sentinel that sorts after
    # any prerelease key (which starts with (0, ...)).
    if not pre:
        return nums + ((1,),)

    # Parse prerelease segments: numeric segments compare as ints, string
    # segments compare as strings. Per semver, numeric < string.
    pre_key = []
    for seg in pre.split("."):
        if seg.isdigit():
            pre_key.append((0, int(seg), ""))
        else:
            pre_key.append((1, 0, seg))
    return nums + (tuple([(0,)] + pre_key),)

def semver_gt(a, b):
    """Returns True if semver string a is greater than semver string b."""
    return parse_semver(a) > parse_semver(b)
