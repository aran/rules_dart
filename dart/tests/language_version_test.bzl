"""Unit tests for derive_language_version."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:language_version.bzl", "derive_language_version")

# (constraint_string, expected_output, label)
_CASES = [
    ("", "2.7", "empty string"),
    ("any", "2.7", "any"),
    ("*", "2.7", "star"),
    ("^3.5.0", "3.5", "caret 3.5.0"),
    ("^3.0.0", "3.0", "caret 3.0.0"),
    ("^2.12.0", "2.12", "caret 2.12.0"),
    ("^3.0.0+1", "3.0", "caret with build metadata"),
    ("^3.0.0-dev.1", "3.0", "caret with prerelease"),
    (">=2.12.0 <4.0.0", "2.12", "range both bounds"),
    (">=2.12.0", "2.12", "range lower only"),
    (">2.12.0", "2.12", "exclusive lower"),
    (">= 2.12.0 <4.0.0", "2.12", "whitespace after operator"),
    (">=2.12.0   <4.0.0", "2.12", "extra whitespace between bounds"),
    ("<4.0.0", "2.7", "upper only"),
    ("<=4.0.0", "2.7", "upper inclusive only"),
    ("2.12.0", "2.12", "bare exact"),
    ("2.12.0+1", "2.12", "bare exact with build metadata"),
    ("2.12.0-pre", "2.12", "bare exact with prerelease"),
    ("3.5.0-dev.7+meta", "3.5", "bare exact with both"),
    ("^2.0.0 || ^3.0.0", "2.0", "union ascending"),
    ("^3.0.0 || ^2.0.0", "2.0", "union descending — pub sorts to smallest min"),
    (">=2.12.0 <3.0.0 || >=3.5.0 <4.0.0", "2.12", "union of full ranges"),
    ("<2.0.0 || ^3.0.0", "2.7", "union — first range (after sort) has no lower bound"),
    ("garbage", "2.7", "malformed"),
    ("12.34.56", "12.34", "two-digit major.minor"),
]

def _table_driven_test_impl(ctx):
    env = unittest.begin(ctx)
    for case in _CASES:
        constraint, expected, label = case
        actual = derive_language_version(constraint)
        asserts.equals(env, expected, actual, "case: " + label)
    return unittest.end(env)

_table_driven_test = unittest.make(_table_driven_test_impl)

def language_version_test_suite(name):
    unittest.suite(name, _table_driven_test)
