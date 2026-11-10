"""Where the import check runs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _library_checked_test_impl(ctx):
    # A `dart_library` is checked by the build of the library itself: any
    # build of it (an analysis run included) must run the import check, as
    # rules_cc ties `layering_check` to the target, including a library
    # nothing executable reaches.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    has_group = OutputGroupInfo in target and hasattr(target[OutputGroupInfo], "_validation")
    asserts.true(env, has_group, "%s has no `_validation` output group: its imports are never checked" % target.label)
    if has_group:
        asserts.true(
            env,
            len(target[OutputGroupInfo]._validation.to_list()) > 0,
            "%s's `_validation` group is empty" % target.label,
        )
    return analysistest.end(env)

library_checked_test = analysistest.make(_library_checked_test_impl)

def import_check_test_suite(name):
    """Registers the tests of where the import check runs.

    Args:
      name: Aggregating `test_suite` target name.
    """
    library_checked_test(
        name = "library_checked_test",
        target_under_test = "//dart/tests/import_check_fixture:lone_lib",
    )
    native.test_suite(name = name, tests = [":library_checked_test"])
