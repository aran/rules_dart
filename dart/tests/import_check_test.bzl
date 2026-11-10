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

def _dependency_edit_test_impl(ctx):
    # The check reads a dependency's file names, not its contents: an edit to a
    # body in a dependency must not rerun the check of what depends on it.
    env = analysistest.begin(ctx)
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(checks))
    if checks:
        check = checks[0]
        argv = " ".join(check.argv)
        asserts.true(env, "lib/base.dart" in argv, "the check no longer names the dependency's file: %s" % argv)
        read = " ".join([f.short_path for f in check.inputs.to_list()])
        asserts.true(env, "lib/user.dart" in read, "the library's own source is not an input: %s" % read)
        asserts.false(env, "lib/base.dart" in read, "a dependency's source is an input of the check: %s" % read)
    return analysistest.end(env)

dependency_edit_test = analysistest.make(_dependency_edit_test_impl)

def _dependency_tree_test_impl(ctx):
    # A dependency that is a directory is listed by the check, so it stays an
    # input: its files can change without its path changing.
    env = analysistest.begin(ctx)
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(checks))
    if checks:
        read = [f for f in checks[0].inputs.to_list() if f.is_directory]
        asserts.true(env, any([f.short_path.endswith("tree_set") for f in read]), "the dependency's directory is not an input of the check: %s" % read)
    return analysistest.end(env)

dependency_tree_test = analysistest.make(_dependency_tree_test_impl)

def import_check_test_suite(name):
    """Registers the tests of where the import check runs.

    Args:
      name: Aggregating `test_suite` target name.
    """
    library_checked_test(
        name = "library_checked_test",
        target_under_test = "//dart/tests/import_check_fixture:lone_lib",
    )
    dependency_edit_test(
        name = "dependency_edit_test",
        target_under_test = "//dart/tests/import_check_fixture/user:user_lib",
    )
    dependency_tree_test(
        name = "dependency_tree_test",
        target_under_test = "//dart/tests/import_check_fixture/tree_user:tree_user_lib",
    )
    native.test_suite(name = name, tests = [":library_checked_test", ":dependency_edit_test", ":dependency_tree_test"])
