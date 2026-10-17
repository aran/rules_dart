"""A YAML parser for the subset that pubspec.yaml and pubspec.lock files use.

`parse_document(content)` returns the value of the first document in
`content`. It builds the same Starlark values that `yaml.bzl` builds (dict,
list, string, int, float, bool, None), in the same insertion order, so the
projections in `dart/pub/yaml_parser.bzl` return what they returned with
yaml.bzl. Scalar typing follows yaml.bzl exactly (`1.10` is a float, `true` a
bool, `~` None, `0x1F` an int), because `str()` of those values reaches the
lock-file output.

Starlark has no recursion and no `while`, so the parser keeps an explicit
stack of open containers and runs bounded `for` loops. Like yaml.bzl in its
default non-strict mode, it never fails on malformed input: it skips lines it
cannot place, and returns None for a flow collection it cannot read.

Supported:
- block mappings and sequences nested by indentation, including `- key: v`
  items, and children that start on the lines after `key:` or `-`
- `#` comments, `---` and `...` markers, `%` directive lines (skipped)
- plain, single-quoted and double-quoted scalars, with yaml.bzl's escapes
- flow collections `[...]` and `{...}`, nested; on a line of their own they
  are read within that line, and a document that starts with one may span
  lines (JSON documents)
- block scalars `|` and `>` with chomping and indentation indicators
- plain scalars continued on more-indented lines
- anchors and aliases, copied shallowly as yaml.bzl copies them
- the tags !!str, !!int, !!float, !!bool, !!null, !!seq and !!map

Divergences from yaml.bzl. None occurs in the pubspec corpus used for parity
testing, so the projections are unaffected on real pubspec files:
- explicit keys (`? key` with `: value`) are dropped; yaml.bzl keeps them
- merge keys (`<<`) are ordinary keys; yaml.bzl merges them into the mapping.
  YAML 1.2 defines no merge keys.
- `%TAG` handles are ignored, so a tag written through one reads as untagged;
  yaml.bzl resolves it. Other unknown tags read as untagged in both.
"""

# Escapes allowed in double-quoted scalars, as yaml.bzl maps them.
_ESCAPES = {
    "0": "\0",
    "a": "\a",
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "v": "\v",
    "f": "\f",
    "r": "\r",
    " ": " ",
    '"': '"',
    "/": "/",
    "\\": "\\",
}

_HEX_DIGITS = "0123456789abcdef"

_FLOW_SPACE = " \t\n\r"

_YAML_TAG_PREFIX = "tag:yaml.org,2002:"

# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

def parse_document(content):
    """Returns the value of the first YAML document in `content`.

    Args:
        content: The text of a YAML stream.

    Returns:
        The document's value, or None when the document is empty.
    """
    lines = _first_document_lines(content)
    text = "\n".join(lines).strip()
    if text[:1] in ["{", "["]:
        return _parse_flow(text, {})
    return _parse_block(lines)

def _first_document_lines(content):
    """Returns the lines of the first document, split as yaml.bzl splits them.

    A `---` line ends the first document once content has been seen. A `...`
    line ends it at any point. A `---` before any content is dropped, unless
    a directive precedes it, in which case it is kept as an ordinary line.
    """
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    current = []
    saw_content = False
    for line in normalized.split("\n"):
        stripped = line.strip()
        if stripped == "---":
            if saw_content:
                return current
            if _has_directive(current):
                current.append(line)
                saw_content = True
            continue
        if stripped == "...":
            return current
        current.append(line)
        if stripped and not stripped.startswith("#") and not stripped.startswith("%"):
            saw_content = True
    return current

def _has_directive(lines):
    for line in lines:
        if line.strip().startswith("%"):
            return True
    return False

# ---------------------------------------------------------------------------
# Block structure
# ---------------------------------------------------------------------------

def _parse_block(lines):
    """Parses the block-structured lines of one document into a value.

    An open container is a frame, a dict {kind, indent, value, entry}. `kind`
    is "map" or "seq", `indent` is the column its entries must be nested
    beyond, and `entry` is the column of its first entry, which later entries
    must match.

    `pending` describes a key or dash whose value is on the following lines:
    the next line indented deeper than it becomes the child container.
    """
    anchors = {}
    root = None
    stack = []
    pending = None
    idx = 0
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("%") or stripped in ["---", "..."]:
            idx += 1
            continue

        indent = _indent_width(raw)
        text = _strip_comment(raw[indent:])
        if text == "":
            idx += 1
            continue

        # Close the containers that this line is not indented into.
        for _ in range(len(stack)):
            if not stack or indent > stack[-1]["indent"]:
                break
            stack.pop()

        if pending != None:
            if indent > pending["indent"]:
                child = _new_block(text)
                pending["parent"][pending["slot"]] = child
                if pending["anchor"] != None:
                    anchors[pending["anchor"]] = child
                stack.append({
                    "kind": "seq" if type(child) == "list" else "map",
                    "indent": pending["indent"],
                    "value": child,
                    "entry": None,
                })
            pending = None

        if root == None and not stack:
            if text == "-" or text.startswith("- "):
                root = []
                stack.append({"kind": "seq", "indent": indent - 1, "value": root, "entry": None})
            elif _find_colon(text) >= 0 or text.startswith("? "):
                root = {}
                stack.append({"kind": "map", "indent": indent - 1, "value": root, "entry": None})
            else:
                root = _parse_scalar(text, anchors)
                idx += 1
                continue

        if not stack:
            idx += 1
            continue

        frame = stack[-1]
        if frame["kind"] == "map":
            idx, pending = _map_line(lines, idx, indent, text, frame, anchors)
        else:
            idx, pending = _seq_line(lines, idx, indent, text, frame, anchors, stack)
    return root

def _map_line(lines, idx, indent, text, frame, anchors):
    """Reads one line of a block mapping. Returns (next index, pending)."""
    if not _entry_indent_ok(frame, indent):
        return idx + 1, None
    if text.startswith("? "):
        # Explicit keys are not supported (see the module docstring).
        return idx + 1, None
    key_text, value_text, ok = _split_key_value(text)
    if not ok or key_text == "":
        return idx + 1, None

    mapping = frame["value"]
    key = _key(_parse_scalar(key_text, anchors))
    anchor = _anchor_only(value_text)
    if value_text == "" or anchor != None:
        _set_first(mapping, key, None)
        return idx + 1, {"parent": mapping, "slot": key, "indent": indent, "anchor": anchor}

    if value_text.startswith("|") or value_text.startswith(">"):
        parsed, next_idx = _parse_block_scalar(lines, idx + 1, indent, value_text)
        _set_first(mapping, key, parsed)
        return next_idx, None

    value = _parse_scalar(value_text, anchors)
    next_idx = idx + 1
    if type(value) == "string" and not _is_quoted(value_text):
        value, next_idx = _consume_plain(lines, idx + 1, indent, value)
    _set_first(mapping, key, value)
    return next_idx, None

def _seq_line(lines, idx, indent, text, frame, anchors, stack):
    """Reads one line of a block sequence. Returns (next index, pending)."""
    if not _entry_indent_ok(frame, indent):
        return idx + 1, None
    if not (text == "-" or text.startswith("- ")):
        return idx + 1, None

    items = frame["value"]
    rest = text[1:].strip()
    if rest == "":
        items.append(None)
        return idx + 1, {"parent": items, "slot": len(items) - 1, "indent": indent, "anchor": None}

    if _find_colon(rest) >= 0:
        # `- key: value` starts a mapping whose first entry is on this line.
        key_text, value_text, _ok = _split_key_value(rest)
        item = {}
        key = _key(_parse_scalar(key_text, anchors))
        _set_first(item, key, _parse_scalar(value_text, anchors) if value_text else None)
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        if value_text == "":
            return idx + 1, {"parent": item, "slot": key, "indent": indent, "anchor": None}
        return idx + 1, None

    if rest.startswith("|") or rest.startswith(">"):
        parsed, next_idx = _parse_block_scalar(lines, idx + 1, indent, rest)
        items.append(parsed)
        return next_idx, None

    value = _parse_scalar(rest, anchors)
    next_idx = idx + 1
    if type(value) == "string" and not _is_quoted(rest):
        value, next_idx = _consume_plain(lines, idx + 1, indent, value)
    items.append(value)
    return next_idx, None

def _new_block(text):
    """The container for a child block, chosen by the first line of the block."""
    return [] if (text == "-" or text.startswith("- ")) else {}

def _entry_indent_ok(frame, indent):
    """Records the column of a container's first entry, then checks `indent`."""
    if frame["entry"] == None:
        frame["entry"] = indent
        return True
    return frame["entry"] == indent

def _anchor_only(value_text):
    """Returns the anchor name when `value_text` is only `&name`, else None."""
    if value_text.startswith("&") and " " not in value_text:
        return value_text[1:]
    return None

def _set_first(mapping, key, value):
    """Stores `value` unless `key` is already present: the first key wins."""
    if key not in mapping:
        mapping[key] = value

def _key(value):
    """Converts a parsed value to a dict key, as yaml.bzl does."""
    t = type(value)
    if t in ["string", "int", "float", "bool", "NoneType"]:
        return value
    if t in ["list", "dict"]:
        return json.encode(value)
    return str(value)

def _consume_plain(lines, start, parent_indent, first):
    """Joins a plain scalar with the more-indented lines that continue it.

    Continuation stops at a line that opens a block entry or a mapping entry.
    Returns (scalar, index of the first line not consumed).
    """
    idx = start
    parts = [first]
    blank_run = 0
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if not raw.strip():
            blank_run += 1
            idx += 1
            continue
        if _indent_width(raw) <= parent_indent:
            break
        text = _strip_comment(raw[_indent_width(raw):])
        if text == "":
            blank_run += 1
            idx += 1
            continue
        if text == "-" or text.startswith("- ") or text.startswith("? ") or text.startswith(": "):
            break
        key_text, _value_text, ok = _split_key_value(text)
        if ok and key_text != "":
            break
        for _ in range(blank_run):
            parts.append("\n")
        parts.append(text)
        blank_run = 0
        idx += 1

    # Parts join with a space, except that a newline run is kept as-is.
    result = ""
    for part in parts:
        if part == "\n":
            result += "\n"
            continue
        if result != "" and not result.endswith("\n"):
            result += " "
        result += part
    return result, idx

# ---------------------------------------------------------------------------
# Block scalars
# ---------------------------------------------------------------------------

def _parse_block_scalar(lines, start, parent_indent, header):
    """Reads a `|` or `>` block scalar. Returns (text, next index).

    `header` is the indicator text after the key or dash, such as `|-` or
    `>2`. The content is every following line indented deeper than
    `parent_indent`, plus the blank lines between them.
    """
    style = header[0]
    chomping = ""
    explicit_indent = 0
    for i in range(1, len(header)):
        ch = header[i]
        if ch in ["+", "-"] and chomping == "":
            chomping = ch
        elif ch.isdigit() and explicit_indent == 0:
            explicit_indent = int(ch)

    idx = start
    raw_lines = []
    min_indent = -1
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if not raw.strip():
            raw_lines.append("")
            idx += 1
            continue
        indent = _indent_width(raw)
        if indent <= parent_indent:
            break
        if min_indent < 0 or indent < min_indent:
            min_indent = indent
        raw_lines.append(raw)
        idx += 1

    if explicit_indent > 0:
        content_indent = parent_indent + explicit_indent
    elif min_indent >= 0:
        content_indent = min_indent
    else:
        content_indent = parent_indent + 1

    values = [raw[content_indent:] if raw != "" else "" for raw in raw_lines]

    if style == "|":
        text = "\n".join(values)
    else:
        text = _fold_lines(values)

    trailing_blank_lines = 0
    for value in reversed(values):
        if value != "":
            break
        trailing_blank_lines += 1

    text = text.rstrip("\n")
    if chomping == "+":
        text += "\n" * (1 + trailing_blank_lines)
    elif chomping == "":
        text += "\n"
    return text, idx

def _fold_lines(values):
    """Folds `>` scalar lines: a single newline becomes a space, blanks stay."""
    pieces = []
    prev_blank = False
    has_text = False
    prev_line = ""
    for line in values:
        if line == "":
            if has_text:
                pieces.append("\n")
            prev_blank = True
            continue
        if has_text:
            if prev_blank or line.startswith(" ") or prev_line.startswith(" "):
                pieces.append("\n")
            else:
                pieces.append(" ")
        pieces.append(line)
        prev_blank = False
        has_text = True
        prev_line = line
    return "".join(pieces)

# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------

def _indent_width(raw):
    """Counts the leading spaces and tabs, each as one column, as yaml.bzl does."""
    return len(raw) - len(raw.lstrip(" \t"))

def _strip_comment(text):
    """Removes a trailing `#` comment, ignoring `#` inside quotes."""
    if "#" not in text:
        return text.rstrip()
    in_single = False
    in_double = False
    escaped = False
    for i in range(len(text)):
        ch = text[i]
        if escaped:
            escaped = False
        elif in_double and ch == "\\":
            escaped = True
        elif ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            if i == 0 or text[i - 1] in [" ", "\t"]:
                return text[:i].rstrip()
    return text.rstrip()

def _find_colon(text):
    """Returns the index of the first top-level `: ` in `text`, or -1.

    A colon inside quotes or brackets does not count, and a trailing colon does.
    """
    if ":" not in text:
        return -1
    in_single = False
    in_double = False
    escaped = False
    braces = 0
    brackets = 0
    for i in range(len(text)):
        ch = text[i]
        if escaped:
            escaped = False
        elif in_double and ch == "\\":
            escaped = True
        elif ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif in_single or in_double:
            continue
        elif ch == "{":
            braces += 1
        elif ch == "}":
            braces -= 1
        elif ch == "[":
            brackets += 1
        elif ch == "]":
            brackets -= 1
        elif ch == ":" and braces == 0 and brackets == 0 and (i + 1 == len(text) or text[i + 1] in [" ", "\t"]):
            return i
    return -1

def _split_key_value(text):
    """Splits `key: value` at the top-level colon. Returns (key, value, found)."""
    c = _find_colon(text)
    if c < 0:
        return "", "", False
    return text[:c].strip(), text[c + 1:].strip(), True

def _is_quoted(text):
    return len(text) >= 2 and ((text[0] == '"' and text[-1] == '"') or (text[0] == "'" and text[-1] == "'"))

# ---------------------------------------------------------------------------
# Scalars
# ---------------------------------------------------------------------------

def _parse_scalar(text, anchors):
    """Parses the text after a key, dash or flow separator into a value.

    Leading `&anchor` and `!tag` words are consumed first. An anchor records
    a shallow copy of the value under its name.
    """
    s = text.strip()
    if s == "":
        return None
    anchor = None
    tag = None
    for _ in range(4):
        if not s:
            break
        if s.startswith("&"):
            parts = s.split(" ", 1)
            anchor = parts[0][1:]
            s = parts[1].strip() if len(parts) > 1 else ""
        elif s.startswith("!"):
            parts = s.split(" ", 1)
            tag = parts[0]
            s = parts[1].strip() if len(parts) > 1 else ""
        else:
            break

    if s[:1] in ["[", "{"]:
        value = _parse_flow(s, anchors)
    else:
        value = _parse_nonflow(s, anchors)
    if tag != None:
        value = _apply_tag(tag, s, value, anchors)
    if anchor:
        anchors[anchor] = _clone(value)
    return value

def _clone(value):
    """A shallow copy of a container, as yaml.bzl makes for aliases."""
    t = type(value)
    if t == "list":
        return list(value)
    if t == "dict":
        return dict(value)
    return value

def _apply_tag(tag, raw, value, anchors):
    """Applies a supported tag to a parsed value. `raw` is the untagged text.

    A tag that names a type the value does not have converts it where yaml.bzl
    does; a conversion that fails gives the type's empty value.
    """
    name = _tag_name(tag)
    if name == "seq" or name == "map":
        want = "list" if name == "seq" else "dict"
        if type(value) == want:
            return value
        parsed = _parse_flow(raw, anchors) if raw[:1] in ["[", "{"] else None
        if type(parsed) == want:
            return parsed
        return [] if name == "seq" else {}
    if name == "str":
        return value if type(value) == "string" else raw
    if name == "int":
        if type(value) == "int":
            return value
        parsed = _parse_int_text(value if type(value) == "string" else raw)
        return parsed if parsed != None else 0
    if name == "float":
        if type(value) == "float":
            return value
        parsed = _parse_float_text(value if type(value) == "string" else raw)
        return parsed if parsed != None else 0.0
    if name == "bool":
        if type(value) == "bool":
            return value
        return (value if type(value) == "string" else raw).strip().lower() in ["true", "yes", "on"]
    if name == "null":
        return None
    return value

def _tag_name(tag):
    """The short name of a tag written as `!!x`, `!x` or `!<tag:yaml.org,2002:x>`."""
    if tag.startswith("!<") and tag.endswith(">"):
        uri = tag[2:-1]
        return uri[len(_YAML_TAG_PREFIX):] if uri.startswith(_YAML_TAG_PREFIX) else None
    if tag.startswith("!!"):
        return tag[2:]
    if tag.startswith("!") and len(tag) > 1 and tag.count("!") == 1:
        return tag[1:]
    return None

def _parse_nonflow(s, anchors):
    """Parses an alias, a quoted scalar or a plain scalar."""
    if s.startswith("*"):
        name = s[1:].strip()
        if name not in anchors:
            return None
        return _clone(anchors[name])
    if _is_quoted(s):
        if s[0] == '"':
            return _unescape_double(s[1:-1])
        return s[1:-1].replace("''", "'")
    if s[:1] in ["@", "`"]:
        return s

    lower = s.lower()
    normalized = _normalize_decimal_number(s)
    num = normalized if normalized != None else s
    if lower in ["null", "~"]:
        return None
    if lower == "true":
        return True
    if lower == "false":
        return False
    if _is_int_digits(num):
        return int(num)
    if len(num) > 2 and num[0:2].lower() == "0x":
        parsed = _parse_based_int(num, 16)
        return parsed if parsed != None else s
    if len(num) > 2 and num[0:2].lower() == "0o":
        parsed = _parse_based_int(num, 8)
        return parsed if parsed != None else s
    if lower in [".inf", "+.inf"]:
        return float("inf")
    if lower == "-.inf":
        return float("-inf")
    if lower == ".nan":
        return float("nan")
    scientific = _parse_scientific_float(num)
    if scientific != None:
        return scientific
    if num.count(".") == 1:
        left, right = num.split(".")
        if _is_decimal_part(left) and right.isdigit():
            return float(num)
    return s

def _is_int_digits(text):
    """True for `123`, `+123` and `-123`."""
    return text.isdigit() or (len(text) > 1 and text[0] in ["-", "+"] and text[1:].isdigit())

def _is_decimal_part(text):
    """True for the part before a decimal point, which may be a bare sign."""
    return _is_int_digits(text) or text in ["-", "+"]

def _normalize_decimal_number(s):
    """Removes `_` digit separators. Returns None when a separator is misplaced."""
    if "_" not in s:
        return s
    if s.startswith("_") or s.endswith("_"):
        return None
    out = []
    for i in range(len(s)):
        ch = s[i]
        if ch != "_":
            out.append(ch)
            continue
        prev = s[i - 1] if i > 0 else ""
        nxt = s[i + 1] if i + 1 < len(s) else ""
        if not (prev.isdigit() and nxt.isdigit()):
            return None
    return "".join(out)

def _parse_scientific_float(text):
    """Parses `1e3`, `1.5E-3` and similar, or returns None."""
    normalized = _normalize_decimal_number(text)
    if normalized == None:
        return None
    s = normalized.lower()
    e = s.find("e")
    if e < 0:
        return None
    left = s[:e]
    right = s[e + 1:]
    if right == "":
        return None
    if right[0] in ["+", "-"]:
        if len(right) == 1 or not right[1:].isdigit():
            return None
    elif not right.isdigit():
        return None
    if _is_int_digits(left):
        return float(normalized)
    if left.count(".") == 1:
        whole, frac = left.split(".")
        if _is_decimal_part(whole) and frac.isdigit():
            return float(normalized)
    return None

def _parse_based_int(text, base):
    """Parses `0x` (base 16) or `0o` (base 8) digits, with `_` separators."""
    s = text.lower()[2:]
    if s == "":
        return None
    normalized = []
    prev_digit = False
    for i in range(len(s)):
        ch = s[i]
        if ch == "_":
            if i == 0 or i == len(s) - 1 or not prev_digit:
                return None
            nxt_pos = _HEX_DIGITS.find(s[i + 1])
            if nxt_pos < 0 or nxt_pos >= base:
                return None
            prev_digit = False
            continue
        pos = _HEX_DIGITS.find(ch)
        if pos < 0 or pos >= base:
            return None
        normalized.append(ch)
        prev_digit = True
    total = 0
    for ch in normalized:
        total = total * base + _HEX_DIGITS.find(ch)
    return total

def _parse_int_text(text):
    """The integer named by a `!!int` value, or None."""
    s = _normalize_decimal_number(text.strip())
    if s == None:
        return None
    if _is_int_digits(s):
        return int(s)
    if len(s) > 2 and s[0:2].lower() == "0x":
        return _parse_based_int(s, 16)
    if len(s) > 2 and s[0:2].lower() == "0o":
        return _parse_based_int(s, 8)
    return None

def _parse_float_text(text):
    """The float named by a `!!float` value, or None."""
    s = _normalize_decimal_number(text.strip())
    if s == None:
        return None
    lower = s.lower()
    if lower in [".inf", "+.inf"]:
        return float("inf")
    if lower == "-.inf":
        return float("-inf")
    if lower == ".nan":
        return float("nan")
    scientific = _parse_scientific_float(s)
    if scientific != None:
        return scientific
    if s.count(".") == 1:
        left, right = s.split(".")
        if _is_decimal_part(left) and right.isdigit():
            return float(s)
    return None

# ---------------------------------------------------------------------------
# Double-quoted escapes
# ---------------------------------------------------------------------------

def _unescape_double(text):
    """Decodes the escapes in the body of a double-quoted scalar.

    An unknown or malformed escape is kept as written, as yaml.bzl keeps it.
    """
    out = []
    i = 0
    for _ in range(len(text) + 1):
        if i >= len(text):
            break
        ch = text[i]
        if ch != "\\" or i + 1 >= len(text):
            out.append(ch)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in _ESCAPES:
            out.append(_ESCAPES[nxt])
            i += 2
        elif nxt == "e":
            out.append(_code_point_text(0x1b))
            i += 2
        elif nxt in ["x", "u", "U"]:
            width = 2 if nxt == "x" else (4 if nxt == "u" else 8)
            if i + 1 + width >= len(text):
                # Too few characters left for the digits: keep the escape letter.
                out.append("\\" + nxt)
                i += 2
                continue
            digits = text[i + 2:i + 2 + width]
            code_point = _parse_hex(digits)
            converted = _code_point_text(code_point) if code_point != None else None
            if converted == None:
                out.append("\\" + nxt + digits)
            else:
                out.append(converted)
            i += 2 + width
        else:
            out.append("\\" + nxt)
            i += 2
    return "".join(out)

def _parse_hex(text):
    if text == "":
        return None
    total = 0
    for i in range(len(text)):
        pos = _HEX_DIGITS.find(text[i].lower())
        if pos < 0:
            return None
        total = total * 16 + pos
    return total

def _code_point_text(code_point):
    """The string for a Unicode code point, or None when it is out of range."""
    if code_point < 0 or code_point > 0x10ffff:
        return None
    if code_point <= 0xffff:
        return json.decode('"\\u%s"' % _hex4(code_point))
    offset = code_point - 0x10000
    high = 0xd800 + offset // 0x400
    low = 0xdc00 + offset % 0x400
    return json.decode('"\\u%s\\u%s"' % (_hex4(high), _hex4(low)))

def _hex4(value):
    out = []
    n = value
    for _ in range(4):
        out.append(_HEX_DIGITS[n % 16])
        n = n // 16
    return "".join(out[::-1])

# ---------------------------------------------------------------------------
# Flow collections
# ---------------------------------------------------------------------------

def _parse_flow(text, anchors):
    """Parses the flow collection that starts `text`, or returns None.

    A flow frame is a dict {kind, close, value, state, key}. `state` is
    "item" or "value" where a value may start, "after" once a value is
    complete, and "key" where a map key is read.
    """
    s = text.strip()
    stack = [_flow_frame(s[:1])]
    i = 1
    for _ in range(len(s) + 1):
        i = _skip_flow_space(s, i)
        if i >= len(s):
            return None
        frame = stack[-1]
        ch = s[i]
        state = frame["state"]

        if ch == frame["close"] and state != "value":
            stack.pop()
            i += 1
            if not stack:
                return frame["value"] if _skip_flow_space(s, i) == len(s) else None
            _flow_add(stack[-1], frame["value"])
            continue

        if state == "after":
            if ch != ",":
                return None
            frame["state"] = "key" if frame["kind"] == "map" else "item"
            i += 1
            continue

        if state == "key":
            token, i = _flow_token(s, i, [":", frame["close"], ","])
            if token == "":
                return None
            frame["key"] = _key(_parse_nonflow(token, anchors))
            i = _skip_flow_space(s, i)
            if i >= len(s) or s[i] != ":":
                return None
            frame["state"] = "value"
            i += 1
            continue

        if ch in ["[", "{"]:
            stack.append(_flow_frame(ch))
            i += 1
            continue
        token, i = _flow_token(s, i, [",", frame["close"]])
        if token == "":
            return None
        _flow_add(frame, _flow_token_value(token, anchors))
    return None

def _flow_frame(opener):
    if opener == "[":
        return {"kind": "seq", "close": "]", "value": [], "state": "item", "key": None}
    return {"kind": "map", "close": "}", "value": {}, "state": "key", "key": None}

def _flow_add(frame, value):
    """Stores a completed value in its collection and expects `,` or the close."""
    if frame["kind"] == "seq":
        frame["value"].append(value)
    else:
        _set_first(frame["value"], frame["key"], value)
    frame["state"] = "after"

def _flow_token_value(token, anchors):
    """A flow token is a scalar, or a one-pair mapping when it contains `: `."""
    key_text, value_text, is_pair = _split_key_value(token)
    if not is_pair:
        return _parse_nonflow(token, anchors)
    pair = {}
    _set_first(pair, _key(_parse_nonflow(key_text, anchors)), _parse_nonflow(value_text, anchors))
    return pair

def _flow_token(s, start, stops):
    """Reads one flow token from `start` up to a stop character.

    Quotes are tracked so that stop characters inside them do not end the
    token. Returns (stripped token, index of the stop character).
    """
    i = start
    in_single = False
    in_double = False
    escaped = False
    for _ in range(len(s) + 1):
        if i >= len(s):
            break
        ch = s[i]
        if escaped:
            escaped = False
        elif in_double and ch == "\\":
            escaped = True
        elif ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif not in_single and not in_double and ch in stops:
            break
        i += 1
    return s[start:i].strip(), i

def _skip_flow_space(s, i):
    return i + len(s[i:]) - len(s[i:].lstrip(_FLOW_SPACE))
