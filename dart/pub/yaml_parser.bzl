"""Reads pubspec.lock files in a module extension.

A lock is machine-written, so it is read in Starlark, with `@yaml.bzl`, where
the extension needs it. A pubspec.yaml is read the way pub reads it, by
`read_pubspec` (`pubspec.bzl`).
"""

load("@yaml.bzl//:yaml.bzl", "yaml")

def _load(content):
    """Parse YAML content into a top-level dict, or None if not a mapping."""
    data = yaml.get_value(yaml.parse(content))
    return data if type(data) == "dict" else None

def parse_pubspec_lock(content):
    """Parse a pubspec.lock file into a dict of package info.

    Args:
        content: String contents of a pubspec.lock file.

    Returns:
        Dict of package_name -> {
            "dependency": str,
            "source": str,
            "version": str,
            "description": dict (keys vary by source type),
        }
    """
    data = _load(content)
    if data == None:
        return {}
    packages = data.get("packages")
    if type(packages) != "dict":
        return {}

    result = {}
    for name, info in packages.items():
        if type(info) != "dict":
            continue
        entry = {}
        for k, v in info.items():
            if k == "description":
                # An inline scalar `description: flutter` is normalised to
                # {"name": "flutter"} so callers can always treat description
                # as a dict.
                if type(v) == "dict":
                    entry["description"] = {sk: str(sv) for sk, sv in v.items()}
                else:
                    entry["description"] = {"name": str(v)}
            else:
                entry[k] = "" if v == None else str(v)
        result[name] = entry
    return result
