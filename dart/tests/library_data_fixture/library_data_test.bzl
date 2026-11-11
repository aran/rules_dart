"""Checks that a `dart_binary` carries the `data` of the libraries it reaches."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_WANTED = [
    "dart/tests/library_data_fixture/fixture.txt",
    "dart/tests/library_data_fixture/helper_data.txt",
]

def _impl(ctx):
    env = analysistest.begin(ctx)
    files = [f.short_path for f in analysistest.target_under_test(env)[DefaultInfo].default_runfiles.files.to_list()]
    for wanted in _WANTED:
        asserts.true(env, wanted in files, "%s missing from runfiles %s" % (wanted, files))
    return analysistest.end(env)

runfiles_hold_test = analysistest.make(_impl)
