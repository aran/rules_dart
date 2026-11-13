"""Analysis-time assertions about `path` packages a lock ignores."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _ignored_package_refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "package `editor_only` (in @@//pub/path:pubspec.lock) is ignored: only the editor reads it")
    return analysistest.end(env)

ignored_package_refused_test = analysistest.make(_ignored_package_refused_impl, expect_failure = True)
