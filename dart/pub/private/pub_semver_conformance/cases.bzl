"""What rules_dart's Starlark says about versions and constraints, to compare with pub_semver.

`version_results` writes, as JSON, this code's answer for every case below.
`conformance_test.dart` computes each answer with `package:pub_semver` itself,
so a case needs no expected value and the two cannot drift apart.
"""

# buildifier: disable=bzl-visibility
load(
    "//dart/pub/private:version.bzl",
    "constraint_allows_key",
    "is_semver",
    "parse_constraint",
    "parse_semver",
)

_MAX = "9223372036854775807"
_OVER = "9223372036854775808"

# Every version each constraint is asked about, and what the orderings compare.
_VERSIONS = [
    "0.0.0",
    "0.0.1-0",
    "0.0.1",
    "0.0.2",
    "0.1.0-0",
    "0.1.0",
    "0.1.1",
    "0.2.0-0",
    "0.2.0-dev",
    "0.2.0",
    "1.0.0-0",
    "1.0.0-1",
    "1.0.0-01",
    "1.0.0-2",
    "1.0.0-10",
    "1.0.0-0a",
    "1.0.0-a",
    "1.0.0-alpha",
    "1.0.0-alpha.1",
    "1.0.0-alpha.beta",
    "1.0.0-beta.2",
    "1.0.0-beta.11",
    "1.0.0-rc.1",
    "1.0.0-rc.1+1",
    "1.0.0-a-b",
    "1.0.0--",
    "1.0.0-" + _MAX,
    "1.0.0-" + _OVER,
    "1.0.0-99999999999999999999",
    "1.0.0",
    "1.0.0+0",
    "1.0.0+1",
    "1.0.0+01",
    "1.0.0+2",
    "1.0.0+10",
    "1.0.0+a",
    "1.0.0+a-b",
    "1.0.0+1.1",
    "1.0.0+" + _OVER,
    "01.00.00",
    "1.0.1-0",
    "1.0.1",
    "1.2.3-dev",
    "1.2.3",
    "1.2.3+4",
    "1.9.9",
    "2.0.0-0",
    "2.0.0-dev.1",
    "2.0.0",
    "2.0.0+1",
    "2.0.1",
    "2.11.0-0",
    "2.11.0",
    "3.0.0-0",
    "3.50.0",
    "3.50.1-0",
    "3.50.1-0.0.pre",
    "3.50.1-0.0.pre-12",
    "3.50.1",
    "3.50.2-0",
    "10.0.0",
    _MAX + ".0.0",
    "0." + _MAX + ".0",
    "0.0." + _MAX,
]

# The bounds combined two at a time, into every pair of comparisons.
_PAIR_BOUNDS = [
    "0.1.0",
    "1.0.0-0",
    "1.0.0-alpha",
    "1.0.0",
    "1.0.0+1",
    "1.0.1",
    "2.0.0-0",
    "2.0.0-dev.1",
    "2.0.0",
    "2.0.0+1",
    "3.50.1-0.0.pre-12",
    "3.50.1",
]

# Constraints written out: the grammar's corners, and what it refuses.
_WRITTEN = [
    "",
    " ",
    "any",
    " any ",
    "\tany\n",
    "ANY",
    "any 1.0.0",
    "1.0.0 any",
    "any any",
    "^",
    "^ 1.0.0",
    "^\t1.0.0",
    " ^1.0.0 ",
    "^1.0.0 <2.0.0",
    "^1.0.0 ",
    "^^1.0.0",
    "^1.0",
    "^any",
    "^1.2.3-dev",
    "^1.2.3+4",
    "^1.0.0-0",
    "^0.0.1",
    "^0.1.2",
    "^0.0.1-dev",
    "^0.0.0",
    "^" + _MAX + ".0.0",
    "^0." + _MAX + ".0",
    "^0.0." + _MAX,
    "^" + _OVER + ".0.0",
    "1",
    "1.0",
    "1.0.",
    "1.0.0.0",
    "v1.0.0",
    "=1.0.0",
    "==1.0.0",
    "!=1.0.0",
    "~1.0.0",
    ">",
    ">=",
    "<",
    "<=",
    ">=1",
    ">=1.0",
    ">= 1.0.0",
    ">=\t1.0.0",
    ">=\n1.0.0",
    "> = 1.0.0",
    "=>1.0.0",
    ">>1.0.0",
    ">=>=1.0.0",
    ">=1.0.0,<2.0.0",
    ">=1.0.0, <2.0.0",
    ">=1.0.0 && <2.0.0",
    "1.0.0||2.0.0",
    "1.0.0 || 2.0.0",
    "^1.0.0 || ^2.0.0",
    "1.0.0-",
    "1.0.0+",
    "1.0.0-+",
    "1.0.0-+a",
    "1.0.0-a+",
    "1.0.0-a.",
    "1.0.0+a.",
    "1.0.0-.a",
    "1.0.0-a..b",
    "1.0.0+a+b",
    "1.0.0-a_b",
    "1.0.0 1.0.0",
    "1.0.0 2.0.0",
    "1.0.02.0.0",
    "1.0.0<2.0.0",
    "1.0.0>0.1.0",
    "1.0.0 >=1.0.0",
    "1.0.0 >1.0.0",
    "1.0.0 <=1.0.0",
    "1.0.0 <1.0.0",
    "1.0.0+1 1.0.0",
    ">=1.0.0 >=2.0.0",
    ">=2.0.0 >=1.0.0",
    ">1.0.0 >=1.0.0",
    ">=1.0.0 >1.0.0",
    "<2.0.0 <3.0.0",
    "<3.0.0 <2.0.0",
    "<2.0.0 <=2.0.0",
    "<=2.0.0 <2.0.0",
    "<2.0.0 >=1.0.0",
    "<2.0.0>=1.0.0",
    ">=2.11.0<3.0.0",
    ">=2.11.0-0<3.0.0-0",
    ">=2.11.0+1<3.0.0+1",
    ">=1.0.0-0 <1.0.0",
    ">=1.0.0-dev <1.0.0",
    ">1.0.0-dev <1.0.0",
    ">=1.0.0 <1.0.0",
    ">=1.0.0+1 <1.0.0",
    ">=1.0.0 <1.0.0+1",
    ">=1.0.0 <=1.0.0",
    ">1.0.0 <=1.0.0",
    ">=2.0.0 <1.0.0",
    "<1.0.0",
    "<=1.0.0",
    "<1.0.0-0",
    "<1.0.0-alpha",
    "<1.0.0+1",
    "<0.0.0",
    _OVER + ".0.0",
    "0." + _OVER + ".0",
    "0.0." + _OVER,
    ">=" + _OVER + ".0.0",
    ">=00000000000000000000001.0.0",
    ">=1.0.0-" + _OVER,
    "<1.0.0-99999999999999999999",
    "\n1.0.0\n",
    "\r\n>=1.0.0\r\n<2.0.0\r\n",
    ">=1.0.0\t<2.0.0",
    ">=1.0.0\013<2.0.0",
    ">=1.0.0\f<2.0.0",
    # Whitespace to Starlark's `strip`, not to Dart's `trim`.
    "\0341.0.0",
    "1.0.0\035",
    ">=1.0.0\036<2.0.0",
    "\0371.0.0",
    # Whitespace to Dart beyond ASCII, in UTF-8: U+0085, U+00A0, U+1680,
    # U+2003, U+2028, U+202F, U+205F, U+3000, U+FEFF.
    "\302\2051.0.0",
    "1.0.0\302\240",
    "\302\240>=1.0.0\302\240<2.0.0\302\240",
    "\341\232\2001.0.0",
    "\342\200\2031.0.0",
    "\342\200\2501.0.0",
    "\342\200\2571.0.0",
    "\342\201\2371.0.0",
    "\343\200\2001.0.0",
    "\357\273\2771.0.0",
    # Not whitespace to either: U+0080, U+200B.
    "\302\2001.0.0",
    "\342\200\2131.0.0",
]

# What the seeded random constraints are made of.
_TOKENS = [
    "1.0.0",
    "2.0.0",
    "0.1.0",
    "1.0",
    "1",
    "0",
    ".",
    "-",
    "+",
    "a",
    "-0",
    "-dev",
    "+1",
    " ",
    "\t",
    "<",
    "<=",
    ">",
    ">=",
    "=",
    "^",
    "any",
    ",",
    "|",
]

_RANDOM_CONSTRAINTS = 2500
_RANDOM_VERSIONS = 1500

def _next(seed):
    # A fixed linear congruential generator: the same cases on every run.
    return (seed * 1103515245 + 12345) % 2147483648

def _random_texts(count, tokens, seed):
    texts = {}
    for _ in range(count):
        seed = _next(seed)
        length = 1 + (seed >> 16) % 7
        words = []
        for _ in range(length):
            seed = _next(seed)
            words.append(tokens[(seed >> 16) % len(tokens)])
        texts["".join(words)] = True
    return texts.keys()

def _constraints():
    texts = {}
    for text in _WRITTEN:
        texts[text] = True
    for version in _VERSIONS:
        texts[version] = True
        texts["^" + version] = True
        for operator in (">=", ">", "<=", "<"):
            texts[operator + version] = True
            texts[operator + " " + version] = True
    for low in _PAIR_BOUNDS:
        for high in _PAIR_BOUNDS:
            for lower in (">=", ">"):
                for upper in ("<", "<="):
                    for gap in ("", " "):
                        texts[lower + low + gap + upper + high] = True
    for text in _random_texts(_RANDOM_CONSTRAINTS, _TOKENS, 20261118):
        texts[text] = True
    return texts.keys()

def _version_texts():
    texts = {version: True for version in _VERSIONS}
    for text in _WRITTEN:
        texts[text] = True
    for text in _random_texts(_RANDOM_VERSIONS, _TOKENS, 3100):
        texts[text] = True
    return texts.keys()

def _results():
    keys = [parse_semver(version) for version in _VERSIONS]
    constraints = []
    for text in _constraints():
        parsed = parse_constraint(text)
        constraints.append({
            "text": text,
            "valid": parsed.error == None,
            "allows": "" if parsed.error != None else "".join([
                "1" if constraint_allows_key(parsed, key) else "0"
                for key in keys
            ]),
        })

    # Each version's place in the order, equal versions sharing one.
    distinct = sorted({key: True for key in keys}.keys())
    ranks = {key: rank for rank, key in enumerate(distinct)}
    return {
        "versions": _VERSIONS,
        "ranks": [ranks[key] for key in keys],
        "constraints": constraints,
        "is_version": {text: is_semver(text) for text in _version_texts()},
    }

def _version_results_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(out, json.encode(_results()))
    return [DefaultInfo(files = depset([out]))]

version_results = rule(
    implementation = _version_results_impl,
    doc = "Writes the Starlark answers for every case, for `conformance_test.dart` to check.",
)
