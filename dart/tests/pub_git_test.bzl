"""Unit tests for the pure parts of dart/pub/private/pub_git.bzl.

A git package is fetched only at a full commit id, from a URL resolved as pub
resolves it, by a git new enough to do what the fetch asks of it.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_git.bzl", "fetch_unset_vars", "git_fetch_url", "is_git_commit_id", "is_relative_git_url", "parse_git_version", "pub_git_resolved_ref_error")
load(":small_suite.bzl", "small_unittest_suite")

_SHA = "0123456789abcdef0123456789abcdef01234567"

def _accepts_full_commit_ids_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_git_commit_id(_SHA), "40 lowercase hex digits")
    asserts.true(env, is_git_commit_id("f" * 40), "all one digit")
    return unittest.end(env)

def _refuses_anything_else_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_git_commit_id(""), "blank")
    asserts.false(env, is_git_commit_id("main"), "a branch")
    asserts.false(env, is_git_commit_id("v1.2.3"), "a tag")
    asserts.false(env, is_git_commit_id("HEAD"), "a symbolic ref")
    asserts.false(env, is_git_commit_id(_SHA[:7]), "an abbreviated id")
    asserts.false(env, is_git_commit_id(_SHA[:39]), "one digit short")
    asserts.false(env, is_git_commit_id(_SHA + "0"), "one digit long")
    asserts.false(env, is_git_commit_id(_SHA.upper()), "uppercase hex")
    asserts.false(env, is_git_commit_id(_SHA + _SHA[:24]), "a SHA-256 repository's id")
    asserts.false(env, is_git_commit_id(_SHA[:39] + "g"), "a non-hex digit")
    return unittest.end(env)

def _resolved_ref_error_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, pub_git_resolved_ref_error("foo", "1.0.0", _SHA, "//:pubspec.lock"))
    with_rewrite = pub_git_resolved_ref_error("foo", "1.0.0", "a1b2c3d", "//:pubspec.lock", rewrite = "bazel run @rules_dart//dart/pub -- get")
    asserts.equals(
        env,
        ('The git package "foo" 1.0.0 (in //:pubspec.lock) is locked at resolved-ref "a1b2c3d", ' +
         "which is not a full commit id (40 lowercase hex digits), so it does not pin what is " +
         "fetched and will not be fetched. Re-resolve the lock, from the root of the workspace " +
         "that holds it, and pub records the commit it resolved as `resolved-ref`:\n" +
         "  bazel run @rules_dart//dart/pub -- get"),
        with_rewrite,
    )
    without = pub_git_resolved_ref_error("foo", "1.0.0", "main", "@foo")
    asserts.true(env, without.endswith("as `resolved-ref`."), without)
    return unittest.end(env)

def _relative_urls_as_pub_reads_them_test_impl(ctx):
    env = unittest.begin(ctx)

    # pub writes a URL relative to the lock's directory when the pubspec
    # named the repository by a relative path.
    asserts.true(env, is_relative_git_url("../other_repo"), "a parent path")
    asserts.true(env, is_relative_git_url("repos/foo.git"), "a child path")
    asserts.true(env, is_relative_git_url("foo"), "a bare name")
    asserts.false(env, is_relative_git_url("https://github.com/a/b.git"), "https")
    asserts.false(env, is_relative_git_url("ssh://git@host/a/b.git"), "ssh")
    asserts.false(env, is_relative_git_url("file:///tmp/remote.git"), "file")
    asserts.false(env, is_relative_git_url("git@github.com:a/b.git"), "an scp-style ssh URL")
    asserts.false(env, is_relative_git_url("/srv/git/b.git"), "an absolute path")
    return unittest.end(env)

def _windows_drive_file_urls_test_impl(ctx):
    env = unittest.begin(ctx)

    # git reads `file:///D:/r` as the path `/D:/r`; only `file://D:/r` names
    # the drive.
    asserts.equals(env, "file://D:/repos/r.git", git_fetch_url("file:///D:/repos/r.git", True), "a drive URL")
    asserts.equals(env, "file://c:/r", git_fetch_url("file:///c:/r", True), "a lowercase drive")
    asserts.equals(env, "file://D:/r", git_fetch_url("file://D:/r", True), "git's form already")
    asserts.equals(env, "file:///srv/r.git", git_fetch_url("file:///srv/r.git", True), "no drive")
    asserts.equals(env, "file:///D:x", git_fetch_url("file:///D:x", True), "a drive-relative path")
    asserts.equals(env, "https://h/D:/r", git_fetch_url("https://h/D:/r", True), "another scheme")
    asserts.equals(env, "file:///D:/r", git_fetch_url("file:///D:/r", False), "elsewhere `/D:/r` is a path")
    return unittest.end(env)

def _git_versions_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, (2, 54), parse_git_version("git version 2.54.0 (Apple Git-157)\n"))
    asserts.equals(env, (2, 45), parse_git_version("git version 2.45.1.windows.1"))
    asserts.equals(env, (2, 14), parse_git_version("git version 2.14.6"))
    asserts.equals(env, None, parse_git_version("not git"))
    return unittest.end(env)

_LOCAL_2_14 = "\n".join([
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_INTERNAL_SUPER_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
]) + "\n"

# Git 2.54 has the count of the environment's config entries too.
_LOCAL_2_54 = _LOCAL_2_14.replace("GIT_CONFIG_PARAMETERS\n", "GIT_CONFIG_PARAMETERS\nGIT_CONFIG_COUNT\n").replace("GIT_INTERNAL_SUPER_PREFIX\n", "")

def _fetch_unsets_only_where_the_repository_is_test_impl(ctx):
    env = unittest.begin(ctx)
    client = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_COMMON_DIR",
        "GIT_ATTR_SOURCE",
        "GIT_SSH_COMMAND",
        "GIT_ASKPASS",
        "GIT_TERMINAL_PROMPT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0",
        "GIT_CONFIG_VALUE_0",
        "HOME",
    ]
    for listed in [_LOCAL_2_14, _LOCAL_2_54]:
        unset = fetch_unset_vars(client, listed)
        asserts.equals(env, sorted([
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_COMMON_DIR",
            "GIT_ATTR_SOURCE",
        ]), sorted(unset.keys()), "only the variables that locate the repository, and GIT_ATTR_SOURCE")
        for value in unset.values():
            asserts.equals(env, None, value, "unset, not emptied")
    return unittest.end(env)

def _fetch_keeps_environment_config_test_impl(ctx):
    env = unittest.begin(ctx)

    # Git lists these as repository variables, but CI hands git credentials
    # and mirrors through them.
    for listed in [_LOCAL_2_14, _LOCAL_2_54]:
        unset = fetch_unset_vars(["GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"], listed)
        asserts.equals(env, {}, unset, "the environment's configuration reaches the fetch")
    return unittest.end(env)

def _fetch_matches_names_without_case_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {"Git_Dir": None}, fetch_unset_vars(["Git_Dir", "Git_Ssh_Command"], _LOCAL_2_54), "Windows folds case")
    asserts.equals(env, {}, fetch_unset_vars([], _LOCAL_2_54), "no client variables")
    return unittest.end(env)

_t0_test = unittest.make(_accepts_full_commit_ids_test_impl)
_t1_test = unittest.make(_refuses_anything_else_test_impl)
_t2_test = unittest.make(_relative_urls_as_pub_reads_them_test_impl)
_t3_test = unittest.make(_git_versions_test_impl)
_t4_test = unittest.make(_fetch_unsets_only_where_the_repository_is_test_impl)
_t5_test = unittest.make(_fetch_keeps_environment_config_test_impl)
_t6_test = unittest.make(_fetch_matches_names_without_case_test_impl)
_t7_test = unittest.make(_windows_drive_file_urls_test_impl)
_t8_test = unittest.make(_resolved_ref_error_test_impl)

def pub_git_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test)
