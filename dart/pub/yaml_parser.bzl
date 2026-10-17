"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Generic YAML parsing is done by `//dart/pub/private:yaml_subset.bzl`; this
module just projects the parsed value down to the exact shapes the rules_dart
pub extension and repository rules consume.
"""

load("//dart/pub/private:yaml_subset.bzl", "parse_document")

def _load(content):
    """Parse YAML content into a top-level dict, or None if not a mapping."""
    data = parse_document(content)
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
                    entry["description"] = {sk: "" if sv == None else str(sv) for sk, sv in v.items()}
                else:
                    entry["description"] = {"name": "" if v == None else str(v)}
            else:
                entry[k] = "" if v == None else str(v)
        result[name] = entry
    return result

def lock_package_error(name, info, lock_file):
    """Validates that a parsed `pubspec.lock` package entry is pinned.

    Hosted packages must carry a non-empty `sha256`, and git packages must
    carry a non-empty `resolved-ref`.

    Args:
        name: Package name from `pubspec.lock`.
        info: Entry dict from `parse_pubspec_lock`.
        lock_file: Label or string identifying the lock file for diagnostics.

    Returns:
        An error string when the entry is unpinned, or None when valid.
    """
    source = info.get("source", "unknown")
    version = info.get("version", "")
    desc = info.get("description", {})
    if source == "hosted":
        if not desc.get("sha256", ""):
            return (
                'pub package "%s" %s in %s has no sha256. ' +
                "Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock."
            ) % (name, version, lock_file)
    elif source == "git":
        if not desc.get("resolved-ref", ""):
            return (
                'pub package "%s" %s in %s has no resolved-ref. ' +
                "Run `dart pub get` and commit the lock."
            ) % (name, version, lock_file)
    return None

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
