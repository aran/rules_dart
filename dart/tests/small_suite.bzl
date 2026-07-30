"""`unittest.suite`, with every generated target declared `size = "small"`.

Skylib's suites leave Bazel's default `medium` size in place — a 300s timeout
for Starlark tests that finish in well under a second. Bazel notices the gap
and prints "There were tests whose specified size is too big" on every run,
which buries real diagnostics in CI logs.

`partial.make` is skylib's documented way to set attributes on the targets
`unittest.suite` generates; there is no plain keyword argument for it.
"""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "unittest")

def small_unittest_suite(name, *test_rules):
    """Declares `unittest.suite(name, *test_rules)` with `size = "small"`.

    Args:
      name: Name of the generated `test_suite`, and prefix of each test target.
      *test_rules: Test rules created by `unittest.make`.
    """
    unittest.suite(
        name,
        *[partial.make(test_rule, size = "small") for test_rule in test_rules]
    )
