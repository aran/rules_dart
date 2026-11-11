"""Tests of what analysis reserves from Bazel's local scheduler.

Analyzing a program's whole source peaks with the program's size, so the
reservation grows with it: a large app reserving a small one's share lets the
scheduler run more analyses at once than the machine can hold.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:resources.bzl", "analysis_resources", "source_analysis_resources")
load(":small_suite.bzl", "small_unittest_suite")

def _memory(dart_files):
    return source_analysis_resources(dart_files)("darwin", 1)["memory"]

def _source_analysis_grows_test_impl(ctx):
    env = unittest.begin(ctx)
    base = analysis_resources("darwin", 1)["memory"]
    asserts.equals(env, base, _memory(0), "a small program reserves the base share")
    asserts.equals(env, base, _memory(2499))
    asserts.true(env, _memory(2500) >= 1200, "a Flutter app's analysis peaks near 1.2 GB on Linux")
    sizes = [0, 1000, 2499, 2500, 5999, 6000, 100000]
    for smaller, larger in zip(sizes[:-1], sizes[1:]):
        asserts.true(
            env,
            _memory(smaller) <= _memory(larger),
            "%d files reserve more than %d" % (smaller, larger),
        )
    asserts.true(env, _memory(6000) > _memory(5999), "the largest programs reserve the most")
    return unittest.end(env)

_source_analysis_grows_test = unittest.make(_source_analysis_grows_test_impl)

def resources_test_suite(name):
    small_unittest_suite(name, _source_analysis_grows_test)
