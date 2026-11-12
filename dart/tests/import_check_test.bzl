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

def _check_argv(env):
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(checks))
    return " ".join(checks[0].argv) if checks else ""

def _unused_checked_test_impl(ctx):
    # A library's own `deps` are judged by the unused check, each by what
    # names it: its files and packages.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    asserts.true(env, "--check-unused" in argv, "the unused check is off: %s" % argv)
    asserts.true(env, "base:base_lib\tfile\t" in argv, "the dependency is not judged by its files: %s" % argv)
    asserts.true(env, "base:base_lib\tpackage\timport_check_base" in argv, "the dependency is not judged by its package: %s" % argv)
    return analysistest.end(env)

unused_checked_test = analysistest.make(_unused_checked_test_impl)

def _used_without_import_test_impl(ctx):
    # A dependency marked `DartUsedWithoutImportInfo` is exempt, never
    # reported, but still listed by its files: an import of one names it, and
    # not another dependency that reaches its package.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    asserts.true(env, "--check-unused" in argv, "the unused check is off: %s" % argv)
    asserts.true(env, ":plugin\texempt" in argv, "a dependency used without an import is not exempt: %s" % argv)
    asserts.true(env, ":plugin\tfile\t" in argv and "base/lib/base.dart" in argv, "an exempt dependency's files are not listed: %s" % argv)
    return analysistest.end(env)

used_without_import_test = analysistest.make(_used_without_import_test_impl)

def _unused_check_off_test_impl(ctx):
    # `features = ["-dart_unused_deps"]` turns the check off for the target.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    asserts.false(env, "--check-unused" in argv, "the unused check runs with its feature off: %s" % argv)
    return analysistest.end(env)

unused_check_off_test = analysistest.make(_unused_check_off_test_impl)

def _unused_names_test_impl(ctx):
    # A macro's target is named by the BUILD file's call, and each dep as that
    # file writes it: `:x` in its package, `//pkg:name` elsewhere.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    package = "//dart/tests/import_check_fixture/unused"
    asserts.true(env, "--dependent %s:call " % package in argv, "the check does not name the macro's call: %s" % argv)
    asserts.true(env, "\tname\t:check_off" in argv, "a dep of the package is not named `:x`: %s" % argv)
    asserts.true(env, "\tname\t//dart/tests/import_check_fixture/base:base_lib" in argv, "a dep elsewhere is not named as written: %s" % argv)

    # The fixer's report is built only when asked for, by its output group.
    target = analysistest.target_under_test(env)
    reports = getattr(target[OutputGroupInfo], "dart_unused_deps", depset()).to_list()
    asserts.equals(env, ["call.program.unused_deps.json"], [f.basename for f in reports])
    return analysistest.end(env)

unused_names_test = analysistest.make(_unused_names_test_impl)

def _generated_uses_test_impl(ctx):
    # The bootstrap a `dart_test` writes uses what it imports, and is not
    # checked itself: the rule's file, not the author's.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    asserts.true(env, "--use-src " in argv and ".vm_test.dart" in argv, "the bootstrap's imports are not uses: %s" % argv)
    srcs = [a for a in argv.split("--src ")[1:] if a.split(" ")[0].endswith(".vm_test.dart")]
    asserts.equals(env, [], srcs, "the bootstrap is checked as the test's own file")
    return analysistest.end(env)

generated_uses_test = analysistest.make(_generated_uses_test_impl)

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
    unused_checked_test(
        name = "unused_checked_test",
        target_under_test = "//dart/tests/import_check_fixture/user:user_lib",
    )
    used_without_import_test(
        name = "used_without_import_test",
        target_under_test = "//dart/tests/import_check_fixture/unused:with_plugin",
    )
    unused_check_off_test(
        name = "unused_check_off_test",
        target_under_test = "//dart/tests/import_check_fixture/unused:check_off",
    )
    used_without_import_test(
        name = "used_without_import_alias_test",
        target_under_test = "//dart/tests/import_check_fixture/unused:through_alias",
    )
    generated_uses_test(
        name = "generated_uses_test",
        target_under_test = "//dart/tests/import_check_fixture/unused:through_helper_test",
    )
    unused_names_test(
        name = "unused_names_test",
        target_under_test = "//dart/tests/import_check_fixture/unused:call.program",
    )
    native.test_suite(name = name, tests = [
        ":used_without_import_alias_test",
        ":unused_names_test",
        ":generated_uses_test",
        ":library_checked_test",
        ":dependency_edit_test",
        ":dependency_tree_test",
        ":unused_checked_test",
        ":used_without_import_test",
        ":unused_check_off_test",
    ])
