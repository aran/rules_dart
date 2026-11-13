"""Reads pubspec.lock files in a module extension.

A lock is machine-written, so it is read in Starlark, with `@yaml.bzl`, where
the extension needs it. A pubspec.yaml is read the way pub reads it, by
`read_pubspec` (`pubspec.bzl`).
"""

load("@yaml.bzl//:yaml.bzl", "yaml")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:version.bzl", "is_semver")

def _entry(name, info):
    """A package entry as callers read it, or a description of why pub refuses it."""
    if type(info) != "dict":
        return "package `{}` is not a mapping".format(name)
    version = info.get("version")
    if type(version) != "string" or not is_semver(version):
        return "package `{}` has no `version` that is a version string (got {})".format(name, repr(version))
    source = info.get("source")
    if type(source) != "string":
        return "package `{}` has no `source` string".format(name)
    if info.get("description") == None:
        return "package `{}` has no `description`".format(name)
    if "dependency" in info and type(info["dependency"]) != "string":
        return "package `{}` has a `dependency` that is not a string".format(name)
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
    return entry

def _read(content):
    """Reads a lock as pub does: `struct(problem, packages)`, one of them None."""

    # pub reads a lock of only whitespace as an empty one.
    if not content.strip():
        return struct(problem = None, packages = {})
    documents = yaml.parse_all(content)
    if len(documents) > 1:
        return struct(problem = "it holds {} YAML documents, and pub expects one".format(len(documents)), packages = None)
    for error in yaml.get_errors(documents[0]):
        problem = error.message if error.line == None else "line {}: {}".format(error.line, error.message)
        return struct(problem = problem, packages = None)
    data = yaml.get_value(documents[0])
    if type(data) != "dict":
        return struct(problem = "its top level is not a mapping", packages = None)

    # `packages` may be left out, but not left empty: `packages:` is null.
    if "packages" not in data:
        return struct(problem = None, packages = {})
    if type(data["packages"]) != "dict":
        return struct(problem = "`packages` is not a mapping", packages = None)
    packages = {}
    for name, info in data["packages"].items():
        entry = _entry(name, info)
        if type(entry) == "string":
            return struct(problem = entry, packages = None)
        packages[name] = entry
    return struct(problem = None, packages = packages)

def lock_error(content):
    """Says why pub would refuse a pubspec.lock, as it does.

    pub reads a lock strictly: one YAML document, no key twice, a mapping of
    packages, each with a `version` string, a `source` string and a
    `description`. A source pub does not know is no reason to refuse. So does this, where a lenient read would pick one of two
    entries for a package listed twice, ignore everything after a second
    `---`, or give no packages for a lock it cannot read.

    Args:
        content: String contents of a pubspec.lock file.

    Returns:
        A description of the first problem, or None for a lock pub accepts.
    """
    return _read(content).problem

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
    read = _read(content)
    if read.problem != None:
        fail("pub would refuse the lock {}: {}".format(source, read.problem))
    return read.packages
