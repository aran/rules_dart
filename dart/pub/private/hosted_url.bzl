"""A hosted pub registry's URL, spelt as pub spells it.

No loads: `build_content.bzl`, `pub_lock_checks.bzl` and `pub_versions.bzl`
load this, and nothing heavier should come with it.
"""

visibility("//dart/...")

_DEFAULT_PORTS = {"http": "80", "https": "443"}

_HEX = "0123456789abcdefABCDEF"

# The characters a URI never needs to escape, by their code in upper-case hex.
_UNRESERVED = dict(
    [("%X" % (0x30 + i), c) for i, c in enumerate("0123456789".elems())] +
    [("%X" % (0x41 + i), c) for i, c in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZ".elems())] +
    [("%X" % (0x61 + i), c) for i, c in enumerate("abcdefghijklmnopqrstuvwxyz".elems())] +
    [("2D", "-"), ("2E", "."), ("5F", "_"), ("7E", "~")],
)

def _escapes(path):
    # Dart's Uri reads `%7e` as `~` and writes other escapes in upper case.
    parts = path.split("%")
    out = [parts[0]]
    for part in parts[1:]:
        code = part[:2].upper()
        if len(code) < 2 or code[0] not in _HEX or code[1] not in _HEX:
            out.append("%" + part)
            continue
        out.append(_UNRESERVED.get(code, "%" + code) + part[2:])
    return "".join(out)

def _without_dot_segments(path):
    segments = path.split("/")[1:]
    out = []
    for segment in segments:
        if segment == "..":
            if out:
                out.pop()
        elif segment != ".":
            out.append(segment)
    return "/" + "/".join(out)

def normalize_hosted_url(url):
    """A registry's URL as pub's `validateAndNormalizeHostedUrl` writes it.

    pub reads every spelling of one registry as one: the scheme and host in
    lower case, no default port, no `.` or `..` segments, a path that ends
    in `/` and no path at all for `/`, and `https://pub.dartlang.org` as
    `https://pub.dev`, which older locks name. A URL pub refuses (not `http`
    or `https`, with no host, with user info, a query or a fragment) is
    returned as written: nothing pub wrote names it, and so it is compared
    only with itself.

    Args:
        url: The registry, as a lock's `description.url` or a declaration
            gives it.

    Returns:
        The URL pub would compare and fetch from.
    """
    scheme, separator, rest = url.partition("://")
    scheme = scheme.lower()
    if not separator or scheme not in _DEFAULT_PORTS or "?" in rest or "#" in rest:
        return url
    slash = rest.find("/")
    authority, path = (rest, "") if slash < 0 else (rest[:slash], rest[slash:])
    if not authority or "@" in authority:
        return url
    host, port = authority, ""
    if authority.startswith("["):
        end = authority.find("]")
        if end < 0 or (end + 1 < len(authority) and authority[end + 1] != ":"):
            return url
        host, port = authority[:end + 1], authority[end + 2:]
    elif ":" in authority:
        host, _, port = authority.partition(":")
    if not host or (port and not port.isdigit()):
        return url
    if port:
        port = str(int(port))
        if port == _DEFAULT_PORTS[scheme]:
            port = ""
    path = _without_dot_segments(_escapes(path)) if path else ""
    if path == "/":
        path = ""
    elif path and not path.endswith("/"):
        path += "/"
    normalized = scheme + "://" + host.lower() + (":" + port if port else "") + path
    return "https://pub.dev" if normalized == "https://pub.dartlang.org" else normalized
