"""Minimal YAML subset parser for pubspec.lock and pubspec.yaml files.

This parser handles the specific YAML patterns found in Dart's pubspec files.
It only supports the subset needed: maps with consistent 2-space indentation,
and string values. No lists, multiline strings, anchors, or aliases.
"""

def _strip_quotes(s):
    """Strip surrounding double or single quotes from a string."""
    if len(s) >= 2:
        if (s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'"):
            return s[1:-1]
    return s

def _indent_level(line):
    """Return the number of leading spaces in a line."""
    return len(line) - len(line.lstrip(" "))

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
    result = {}
    lines = content.split("\n")
    in_packages = False
    current_pkg = None
    current_data = {}
    in_description = False

    for line in lines:
        stripped = line.strip()

        # Skip empty lines and comments
        if not stripped or stripped.startswith("#"):
            continue

        indent = _indent_level(line)

        # Look for the packages: section
        if indent == 0:
            if stripped == "packages:":
                in_packages = True
                continue
            else:
                # Any other top-level key ends the packages section
                if in_packages:
                    if current_pkg:
                        result[current_pkg] = current_data
                    in_packages = False
                continue

        if not in_packages:
            continue

        if indent == 2:
            # Package name line
            if current_pkg:
                result[current_pkg] = current_data
            current_pkg = stripped.rstrip(":")
            current_data = {}
            in_description = False

        elif indent == 4:
            # Package attribute
            colon_pos = stripped.find(":")
            if colon_pos < 0:
                continue
            key = stripped[:colon_pos].strip()
            value = stripped[colon_pos + 1:].strip()

            if key == "description":
                if value:
                    # Inline description (e.g., "description: flutter")
                    current_data["description"] = {"name": _strip_quotes(value)}
                else:
                    current_data["description"] = {}
                in_description = True
            else:
                current_data[key] = _strip_quotes(value)
                in_description = False

        elif indent == 6 and in_description:
            # Description sub-attribute
            colon_pos = stripped.find(":")
            if colon_pos < 0:
                continue
            key = stripped[:colon_pos].strip()
            value = _strip_quotes(stripped[colon_pos + 1:].strip())
            current_data["description"][key] = value

    # Save last package
    if current_pkg:
        result[current_pkg] = current_data

    return result

def parse_pubspec_deps(content):
    """Extract dependency names from a pubspec.yaml file.

    Only extracts package names from the `dependencies:` section.

    Args:
        content: String contents of a pubspec.yaml file.

    Returns:
        List of dependency package names.
    """
    deps = []
    in_deps = False

    for line in content.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = _indent_level(line)

        if indent == 0:
            in_deps = (stripped == "dependencies:")
        elif in_deps and indent == 2:
            # Dependency entry
            colon_pos = stripped.find(":")
            if colon_pos > 0:
                dep_name = stripped[:colon_pos].strip()
                if dep_name and not dep_name.startswith("#"):
                    deps.append(dep_name)

    return deps
