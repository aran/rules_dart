"""An analysis test that `resolve` refuses a target building another package."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _wrong_package_refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "maps package `characters` to @@//pub_resolve_wrong_package/not_characters:not_characters, which is the Dart package `not_characters`")
    return analysistest.end(env)

wrong_package_refused_test = analysistest.make(_wrong_package_refused_impl, expect_failure = True)
