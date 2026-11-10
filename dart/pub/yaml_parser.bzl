"""Reads pubspec.lock files in a module extension.

A lock is machine-written, so it is read in Starlark, with `@yaml.bzl`, where
the extension needs it. A pubspec.yaml is read the way pub reads it, by
`read_pubspec` (`pubspec.bzl`).
"""

load("@yaml.bzl//:yaml.bzl", "yaml")

def lock_error(content):
    """Says why pub would refuse a pubspec.lock, as it does.

    pub reads a lock strictly: one YAML document, no key twice. So does this,
    where a lenient read would pick one of two entries for a package listed
    twice, or ignore everything after a second `---`.

    Args:
        content: String contents of a pubspec.lock file.

    Returns:
        A description of the first problem, or None for a lock pub accepts.
    """
    documents = yaml.parse_all(content)
    if len(documents) > 1:
        return "it holds {} YAML documents, and pub expects one".format(len(documents))
    for error in yaml.get_errors(documents[0]):
        if error.line == None:
            return error.message
        return "line {}: {}".format(error.line, error.message)
    return None

def _load(content):
    """Parse YAML content into a top-level dict, or None if not a mapping."""
    data = yaml.get_value(yaml.parse(content))
    return data if type(data) == "dict" else None

def parse_pubspec_lock(content, source):
    """Parse a pubspec.lock file into a dict of package info.

    Fails, naming the lock, where pub would refuse it (see `lock_error`).

    Args:
        content: String contents of a pubspec.lock file.
        source: The lock as a message names it, such as its label.

    Returns:
        Dict of package_name -> {
            "dependency": str,
            "source": str,
            "version": str,
            "description": dict (keys vary by source type),
        }
    """
    problem = lock_error(content)
    if problem != None:
        fail("pub would refuse the lock {}: {}".format(source, problem))
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
