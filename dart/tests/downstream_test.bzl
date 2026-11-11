"""Tests that another rule set can declare and resolve `package` as rules_dart's rules do.

The rule under test, `downstream_library` (`downstream_fixture/rules.bzl`), is
defined outside `dart/private` and loads only `//dart:utils.bzl` and
`//dart:providers.bzl`: `package_identity_attrs()` for the attribute,
`library_package` and `executable_package_record` for the record and the check.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")

def _record(target):
    if DartAnalyzableInfo in target:
        return target[DartAnalyzableInfo].dart_info.packages[0]
    return target[DartInfo].packages[0]

def _record_test_impl(ctx):
    env = analysistest.begin(ctx)
    mine = _record(analysistest.target_under_test(env))
    asserts.equals(env, ctx.attr.expected_package_name, mine.package_name)
    asserts.equals(env, ctx.attr.expected_package_root, mine.package_root)
    asserts.equals(env, ctx.attr.expected_language_version, mine.language_version)
    asserts.equals(env, ctx.attr.expected_metadata, str(mine.metadata) if mine.metadata else "")
    if ctx.attr.same_as:
        theirs = _record(ctx.attr.same_as)
        for field in ["package_name", "package_root", "version", "language_version", "code_assets", "unreplaced_hook", "link_hook", "link_hook_assets", "license_file", "metadata"]:
            asserts.equals(env, getattr(theirs, field), getattr(mine, field), "`%s` differs from rules_dart's record" % field)
    return analysistest.end(env)

# The record a downstream rule builds, and that it is the one rules_dart's rule
# builds for the same declaration.
downstream_record_test = analysistest.make(
    _record_test_impl,
    attrs = {
        "expected_package_name": attr.string(mandatory = True),
        "expected_package_root": attr.string(mandatory = True),
        "expected_language_version": attr.string(),
        "expected_metadata": attr.string(),
        "same_as": attr.label(),
    },
)

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

# A `downstream_library` the shared check refuses, and the error that says so.
downstream_refused_test = analysistest.make(
    _refused_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)
