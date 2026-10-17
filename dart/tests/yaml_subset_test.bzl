"""Unit tests for dart/pub/private/yaml_subset.bzl, the pubspec YAML parser.

Expected values match what yaml.bzl returns for the same text. The parity
check against yaml.bzl ran over a corpus of real pubspec files and generated
documents; these cases pin the constructs it covers.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:yaml_subset.bzl", "parse_document")
load(":small_suite.bzl", "small_unittest_suite")

def _block_mapping_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": 1, "b": {"c": "x", "d": {"e": True}}},
        parse_document("a: 1\nb:\n  c: x\n  d:\n    e: true\n"),
    )
    return unittest.end(env)

def _block_sequence_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["x", ["y", "z"], {"k": "v", "n": 3}, "tail"],
        parse_document("- x\n-\n  - y\n  - z\n- k: v\n  n: 3\n- tail\n"),
    )
    return unittest.end(env)

def _same_indent_sequence_test_impl(ctx):
    env = unittest.begin(ctx)

    # A sequence under a key at the key's own indent is dropped, as yaml.bzl
    # drops it: the dash line is not an entry of the mapping.
    asserts.equals(env, {"a": None, "b": 1}, parse_document("a:\n- x\nb: 1\n"))
    return unittest.end(env)

def _comment_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": 1, "b": "x # not", "c": "x#y", "d": "q # r", "e": "plain"},
        parse_document("a: 1 # trailing\n# full line\nb: 'x # not' # yes\nc: x#y\nd: \"q # r\"\ne: plain\n"),
    )
    return unittest.end(env)

def _document_marker_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {"a": 1}, parse_document("---\na: 1\n...\nb: 2\n"))
    asserts.equals(env, {"a": 1}, parse_document("a: 1\n---\nb: 2\n"))
    asserts.equals(env, {"a": 1}, parse_document("%YAML 1.2\n---\na: 1\n"))
    asserts.equals(env, None, parse_document(""))
    asserts.equals(env, None, parse_document("# only a comment\n"))
    return unittest.end(env)

def _plain_scalar_type_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: 1\nb: 1.10\nc: true\nd: True\ne: ~\nf:\ng: null\nh: 0x1F\ni: 0o17\n" +
        "j: 1_000\nk: .inf\nl: -.inf\nm: 1e3\nn: 1.5E-3\no: 1.2.3\np: 007\nq: -1\n",
    )

    asserts.equals(env, 1, parsed["a"])
    asserts.equals(env, "int", type(parsed["a"]))

    # An unquoted decimal is a float, so str() drops the trailing zero.
    asserts.equals(env, "float", type(parsed["b"]))
    asserts.equals(env, "1.1", str(parsed["b"]))

    asserts.equals(env, True, parsed["c"])
    asserts.equals(env, True, parsed["d"])
    asserts.equals(env, None, parsed["e"])
    asserts.equals(env, None, parsed["f"])
    asserts.equals(env, None, parsed["g"])
    asserts.equals(env, 31, parsed["h"])
    asserts.equals(env, 15, parsed["i"])
    asserts.equals(env, 1000, parsed["j"])
    asserts.equals(env, "float", type(parsed["k"]))
    asserts.equals(env, "float", type(parsed["l"]))
    asserts.equals(env, "float", type(parsed["m"]))
    asserts.equals(env, 1000.0, parsed["m"])
    asserts.equals(env, 0.0015, parsed["n"])
    asserts.equals(env, "1.2.3", parsed["o"])
    asserts.equals(env, 7, parsed["p"])
    asserts.equals(env, -1, parsed["q"])
    return unittest.end(env)

def _quoted_scalar_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {
            "a": "it's",
            "b": "x\ty\n\"q\" \\ /",
            "c": "Aé",
            "d": "\\q",
            "e": "1.10",
            "f": "# not a comment",
        },
        parse_document(
            "a: 'it''s'\n" +
            "b: \"x\\ty\\n\\\"q\\\" \\\\ \\/\"\n" +
            "c: \"\\x41\\u00e9\"\n" +
            "d: \"\\q\"\n" +
            "e: '1.10'\n" +
            "f: '# not a comment'\n",
        ),
    )
    return unittest.end(env)

def _flow_collection_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {
            "a": {"path": "../x", "git": {"url": "u", "ref": "main"}},
            "b": [1, [2, 3], {"x": "y"}],
            "c": [],
            "d": {},
            "e": ["a"],
            "f": ["q", "r"],
            "g": None,
            "h": 1,
        },
        parse_document(
            "a: {path: ../x, git: {url: 'u', ref: main}}\n" +
            "b: [1, [2, 3], {x: y}]\n" +
            "c: []\n" +
            "d: {}\n" +
            "e: [a,]\n" +
            "f: [\"q\", 'r']\n" +
            "g: [1, 2\n" +
            "h: 1\n",
        ),
    )
    return unittest.end(env)

def _block_scalar_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: |\n  one\n  two\n" +
        "b: >\n  folded\n  text\n\n  next\n" +
        "c: |-\n  strip\n" +
        "d: |+\n  keep\n\n" +
        "e: |2\n    indented\n" +
        "f: 1\n",
    )
    asserts.equals(env, "one\ntwo\n", parsed["a"])

    # yaml.bzl turns a blank line in a folded scalar into two newlines, where
    # YAML 1.2 specifies one. The parity check requires yaml.bzl's output.
    asserts.equals(env, "folded text\n\nnext\n", parsed["b"])
    asserts.equals(env, "strip", parsed["c"])
    asserts.equals(env, "keep\n\n", parsed["d"])
    asserts.equals(env, "  indented\n", parsed["e"])
    asserts.equals(env, 1, parsed["f"])
    return unittest.end(env)

def _plain_continuation_test_impl(ctx):
    env = unittest.begin(ctx)

    # A continuation line that looks like a mapping entry ends the scalar. The
    # entry itself is then at the wrong indent and is skipped, as in yaml.bzl.
    asserts.equals(
        env,
        {"a": "one two", "b": "y"},
        parse_document("a: one\n  two\n  three: x\nb: y\n"),
    )
    asserts.equals(env, {"a": "plain\ntext"}, parse_document("a: plain\n\n  text\n"))
    return unittest.end(env)

def _anchor_alias_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"base": {"x": 1}, "child": {"x": 1}, "s": "hello", "t": "hello", "u": None},
        parse_document("base: &b\n  x: 1\nchild: *b\ns: &v hello\nt: *v\nu: *none\n"),
    )
    return unittest.end(env)

def _tag_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_document(
        "a: !!str 1.10\nb: !!int '12'\nc: !!float 3\nd: !!bool yes\n" +
        "e: !!null x\nf: !!int 1.5\ng: !!bool maybe\n" +
        "h: !<tag:yaml.org,2002:str> 2.0\ni: !str 3.0\n",
    )
    asserts.equals(env, "1.10", parsed["a"])
    asserts.equals(env, 12, parsed["b"])

    # yaml.bzl reads `!!float 3` as 0.0: its float reader wants a decimal point.
    asserts.equals(env, 0.0, parsed["c"])
    asserts.equals(env, True, parsed["d"])
    asserts.equals(env, None, parsed["e"])
    asserts.equals(env, 0, parsed["f"])
    asserts.equals(env, False, parsed["g"])
    asserts.equals(env, "2.0", parsed["h"])
    asserts.equals(env, "3.0", parsed["i"])
    return unittest.end(env)

def _collection_tag_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": [1, 2], "b": {"x": 1}, "c": [], "d": {}},
        parse_document("a: !!seq [1, 2]\nb: !!map {x: 1}\nc: !!seq 3\nd: !!map []\n"),
    )
    return unittest.end(env)

def _json_document_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"a": [1, 2], "b": {"c": None, "d": "é"}},
        parse_document('{\n  "a": [1,\n    2],\n  "b": {"c": null, "d": "\\u00e9"}\n}\n'),
    )
    return unittest.end(env)

def _duplicate_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # The first scalar wins. A later block replaces what was there, as yaml.bzl does.
    asserts.equals(env, {"a": 1}, parse_document("a: 1\na: 2\n"))
    asserts.equals(env, {"a": {"c": 2}}, parse_document("a:\n  b: 1\na:\n  c: 2\n"))
    return unittest.end(env)

def _indentation_test_impl(ctx):
    env = unittest.begin(ctx)

    # Entries at a different indent from the first entry are skipped.
    asserts.equals(env, {"a": {"b": 1}}, parse_document("a:\n    b: 1\n  c: 2\n"))
    asserts.equals(env, {"a": {"b": 1}}, parse_document("a:\n\tb: 1\n"))
    asserts.equals(env, {"a": 1, "b": 2}, parse_document("a: 1\r\nb: 2\r\n"))
    return unittest.end(env)

def _explicit_key_and_merge_test_impl(ctx):
    env = unittest.begin(ctx)

    # Divergences from yaml.bzl, recorded in the module docstring.
    asserts.equals(env, {"b": 2}, parse_document("? a\n: 1\nb: 2\n"))
    asserts.equals(
        env,
        {"base": {"x": 1}, "child": {"<<": {"x": 1}, "y": 2}},
        parse_document("base: &b\n  x: 1\nchild:\n  <<: *b\n  y: 2\n"),
    )
    return unittest.end(env)

def _malformed_input_test_impl(ctx):
    env = unittest.begin(ctx)

    # Malformed input must not fail the build, whatever it returns.
    for text in [
        "[",
        "{",
        "a: [",
        "- :",
        "&",
        "*",
        "!",
        "a: !<",
        "a: 'unterminated",
        "a: \"\\u12\"",
        "a: \"\\U00110000\"",
        "a:\n\t- x",
        "- - -",
        "---\n---\n",
        "...",
        "%",
        "a: {b: }",
        "a: [1,,2]",
        "[1, 2] trailing",
        "{\"a\": 1",
    ]:
        parse_document(text)
    asserts.true(env, True)
    return unittest.end(env)

_t0_test = unittest.make(_block_mapping_test_impl)
_t1_test = unittest.make(_block_sequence_test_impl)
_t2_test = unittest.make(_same_indent_sequence_test_impl)
_t3_test = unittest.make(_comment_test_impl)
_t4_test = unittest.make(_document_marker_test_impl)
_t5_test = unittest.make(_plain_scalar_type_test_impl)
_t6_test = unittest.make(_quoted_scalar_test_impl)
_t7_test = unittest.make(_flow_collection_test_impl)
_t8_test = unittest.make(_block_scalar_test_impl)
_t9_test = unittest.make(_plain_continuation_test_impl)
_t10_test = unittest.make(_anchor_alias_test_impl)
_t11_test = unittest.make(_tag_test_impl)
_t12_test = unittest.make(_collection_tag_test_impl)
_t13_test = unittest.make(_json_document_test_impl)
_t14_test = unittest.make(_duplicate_key_test_impl)
_t15_test = unittest.make(_indentation_test_impl)
_t16_test = unittest.make(_explicit_key_and_merge_test_impl)
_t17_test = unittest.make(_malformed_input_test_impl)

def yaml_subset_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
    )
