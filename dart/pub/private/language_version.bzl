"""Derive a Dart language version from an `environment.sdk` constraint string.

Replicates `pub`'s `LanguageVersion.fromSdkConstraint` from
`dart-lang/pub/lib/src/language_version.dart`. The output is the value pub
writes into the `languageVersion` field of each `package_config.json` entry —
`<major>.<minor>` form, defaulting to `"2.7"` when the constraint is missing
or has no lower bound.

The algorithm mirrors pub's source:

  - Empty / `null` constraint → DEFAULT (`"2.7"`).
  - Caret (`^X.Y.Z`) → `"X.Y"`.
  - Range (`>=X.Y.Z <A.B.C`, `>=X.Y.Z`, `>X.Y.Z`, etc.) → lower bound's
    `<major>.<minor>`. If only an upper bound is present, → DEFAULT.
  - Bare exact version (`X.Y.Z`) → `"X.Y"`.
  - Union (`alt1 || alt2`) → derive on each alternative; take the result
    corresponding to the smallest min (or DEFAULT if any alternative has no
    lower bound and that one sorts first). Pub sorts internally; users
    typically write unions in ascending order.

Patch / prerelease / build-metadata suffixes are dropped before formatting.

The DEFAULT (`"2.7"`) is intentionally fixed at the version pub adopted
language versioning at. It is **not** the running SDK's language version. See
the `defaultLanguageVersion` const in pub's source.
"""

DEFAULT_LANGUAGE_VERSION = "2.7"

def derive_language_version(sdk_constraint):
    """Compute the language version string implied by an `environment.sdk` constraint.

    Args:
        sdk_constraint: Verbatim string from `pubspec.yaml`'s `environment.sdk`
            field, or empty / `None` if the constraint is missing.

    Returns:
        A `<major>.<minor>` language version string.
    """
    if not sdk_constraint:
        return DEFAULT_LANGUAGE_VERSION
    s = sdk_constraint.strip()
    if not s or s == "any" or s == "*":
        return DEFAULT_LANGUAGE_VERSION

    # VersionUnion: pick the alternative with the smallest min. If that
    # alternative lacks a lower bound, fall back to DEFAULT (matches pub:
    # ranges.first.min is null → return defaultLanguageVersion).
    if "||" in s:
        scored = [(_min_sort_key(alt.strip()), alt.strip()) for alt in s.split("||")]
        scored = sorted(scored, key = lambda t: t[0])
        first_key, first_alt = scored[0]

        # Sentinel for "no lower bound" → pub returns DEFAULT.
        if first_key == _MIN_KEY_NONE:
            return DEFAULT_LANGUAGE_VERSION
        return _derive_single(first_alt)

    return _derive_single(s)

def _derive_single(s):
    """Derive language version from a single (non-union) constraint string."""
    if not s or s == "any" or s == "*":
        return DEFAULT_LANGUAGE_VERSION

    # Caret: ^X.Y.Z[+meta][-prerelease].
    if s.startswith("^"):
        return _major_minor(s[1:].strip())

    # Range form: collapse `>= 2.12.0` to `>=2.12.0` for tokenisation.
    s_compact = _compact_operators(s)
    tokens = [t for t in s_compact.split(" ") if t]

    lower = None
    has_upper = False
    for tok in tokens:
        if tok.startswith(">="):
            lower = tok[2:]
        elif tok.startswith(">"):
            lower = tok[1:]
        elif tok.startswith("<"):
            has_upper = True
    if lower:
        return _major_minor(lower)
    if has_upper:
        return DEFAULT_LANGUAGE_VERSION

    # Bare exact version.
    return _major_minor(s)

# Sentinel: when an alternative has no lower bound, sort it before any
# numeric (major, minor) tuple. Tuples are compared element-wise so this
# tuple of three ints sorts strictly less than any (major, minor, _) tuple
# the version-parsing path can produce.
_MIN_KEY_NONE = (-1, -1, -1)

def _min_sort_key(alt):
    """Compute a sort key for a union alternative.

    Returns `_MIN_KEY_NONE` for alternatives with no lower bound (pub treats
    these as sorting first). Otherwise returns a `(major, minor, 0)` tuple
    derived from the alternative's lower-bound version.
    """
    a = alt.strip()
    if not a or a == "any" or a == "*":
        return _MIN_KEY_NONE
    if a.startswith("^"):
        return _version_sort_key(a[1:])
    a_compact = _compact_operators(a)
    tokens = [t for t in a_compact.split(" ") if t]
    lower = None
    for tok in tokens:
        if tok.startswith(">="):
            lower = tok[2:]
        elif tok.startswith(">"):
            lower = tok[1:]
    if lower:
        return _version_sort_key(lower)
    has_upper = False
    for tok in tokens:
        if tok.startswith("<"):
            has_upper = True
            break
    if has_upper:
        return _MIN_KEY_NONE
    return _version_sort_key(a)

def _version_sort_key(version_str):
    """Compute a `(major, minor, 0)` sort key from a version string.

    Returns `_MIN_KEY_NONE` when the version cannot be parsed.
    """
    mm = _major_minor(version_str)
    if mm == DEFAULT_LANGUAGE_VERSION and not _looks_like_default_version(version_str):
        return _MIN_KEY_NONE
    parts = mm.split(".")
    return (int(parts[0]), int(parts[1]), 0)

def _looks_like_default_version(version_str):
    """Distinguish a parse-failure DEFAULT from a literal "2.7"-shaped input."""
    v = version_str.strip()
    if "+" in v:
        v = v[:v.index("+")]
    if "-" in v:
        v = v[:v.index("-")]
    parts = v.split(".")
    return len(parts) >= 2 and parts[0] == "2" and parts[1] == "7"

def _compact_operators(s):
    """Collapse whitespace between comparison operators and their versions.

    Handles `>= 2.12.0` → `>=2.12.0`. pub_semver permits the optional
    whitespace; pubspec authors sometimes use it.
    """
    out = ""
    i = 0
    n = len(s)
    operators = [">=", "<=", ">", "<"]
    for _ in range(n + 1):
        if i >= n:
            break
        matched = False
        for op in operators:
            ol = len(op)
            if s[i:i + ol] == op:
                out += op
                i += ol
                for _ in range(n):
                    if i < n and s[i] == " ":
                        i += 1
                    else:
                        break
                matched = True
                break
        if not matched:
            out += s[i]
            i += 1
    return out

def _major_minor(version_str):
    """Extract `<major>.<minor>` from a version string. Returns DEFAULT on parse failure."""
    v = version_str.strip()
    if "+" in v:
        v = v[:v.index("+")]
    if "-" in v:
        v = v[:v.index("-")]
    parts = v.split(".")
    if len(parts) < 2:
        return DEFAULT_LANGUAGE_VERSION
    major = parts[0]
    minor = parts[1]
    if not major.isdigit() or not minor.isdigit():
        return DEFAULT_LANGUAGE_VERSION
    return major + "." + minor
