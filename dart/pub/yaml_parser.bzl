"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Generic YAML parsing is delegated to `@yaml.bzl//:yaml.bzl`; this module
just projects the parsed value down to the exact shapes the rules_dart
pub extension and repository rules consume.
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

def parse_pubspec_deps(content):
    """Extract dependency names from a pubspec.yaml file.

    Only extracts package names from the `dependencies:` section.

    Args:
        content: String contents of a pubspec.yaml file.

    Returns:
        List of dependency package names.
    """
    data = _load(content)
    if data == None:
        return []
    deps = data.get("dependencies")
    if type(deps) != "dict":
        return []
    return list(deps.keys())

def parse_pubspec_sdk_constraint(content):
    """Extract the `environment.sdk` constraint from a pubspec.yaml file.

    Returns the value of `environment.sdk` as a string. Returns the empty
    string when the constraint is missing.

    Args:
        content: String contents of a pubspec.yaml file.

    Returns:
        The SDK version constraint string, e.g. `^3.5.0` or `>=2.12.0 <4.0.0`.
    """
    data = _load(content)
    if data == None:
        return ""
    env = data.get("environment")
    if type(env) != "dict":
        return ""
    sdk = env.get("sdk")
    if sdk == None:
        return ""
    return str(sdk)
