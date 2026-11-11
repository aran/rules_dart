"""Unit tests for `select_pub_version`, the one policy for a hosted package's version."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pub_versions.bzl", "pub_version_request", "select_pub_version")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_settings.bzl", "root_only_settings")
load(":small_suite.bzl", "small_unittest_suite")

_PUB = "https://pub.dev"

def _req(version, is_root = False, where = None, sha256 = None, url = _PUB, upgrade = "", refresh = ""):
    return pub_version_request(
        version = version,
        sha256 = sha256 or ("sha-" + version),
        url = url,
        is_root = is_root,
        where = where or ("the root module" if is_root else "module `dep`"),
        upgrade = upgrade,
        refresh = refresh,
    )

def _contains(env, text, *fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "expected {} in:\n{}".format(repr(fragment), text))

def _highest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("1.0.0"), _req("1.10.0", where = "b"), _req("1.9.0", where = "c")])
    asserts.equals(env, "1.10.0", s.request.version)
    asserts.equals(env, "b", s.request.where)
    asserts.equals(env, None, s.warning)
    asserts.equals(env, None, s.error)
    return unittest.end(env)

def _first_at_highest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("2.0.0", where = "a"), _req("2.0.0", where = "b")])
    asserts.equals(env, "a", s.request.where)
    return unittest.end(env)

def _raising_a_dependency_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("2.0.0", is_root = True), _req("1.0.0")], "error")
    asserts.equals(env, "2.0.0", s.request.version)
    asserts.equals(env, None, s.warning)
    asserts.equals(env, None, s.error)
    return unittest.end(env)

def _raised_root_warns_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("tuple", [
        _req("2.0.1", is_root = True, where = "`pub.package()` in the root module"),
        _req("2.0.2", where = "`pub.package()` in module `dep_mod`", sha256 = "abc"),
    ])
    asserts.equals(env, "2.0.2", s.request.version)
    asserts.equals(env, None, s.error)
    _contains(
        env,
        s.warning,
        "Package \"tuple\" is built at 2.0.2, newer than the root module asks for",
        "2.0.1, from `pub.package()` in the root module",
        "2.0.2, from `pub.package()` in module `dep_mod`",
        "version = \"2.0.2\", sha256 = \"abc\"",
        "pub.settings(check_direct_dependencies = \"off\")",
    )
    return unittest.end(env)

def _raised_root_lock_gives_its_command_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("path", [
        _req("1.9.1", is_root = True, where = "the lock `//a:pubspec.lock`"),
        _req("1.9.0", is_root = True, where = "the lock `//b:pubspec.lock`", upgrade = "UPGRADE b path"),
    ])
    asserts.equals(env, "1.9.1", s.request.version)
    _contains(env, s.warning, "1.9.0, from the lock `//b:pubspec.lock`", "  UPGRADE b path")
    _contains(env, s.warning, "Raised by:\n  - 1.9.1, from the lock `//a:pubspec.lock`")
    return unittest.end(env)

def _error_level_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("1.0.0", is_root = True), _req("1.1.0")], "error")
    asserts.equals(env, None, s.request)
    asserts.equals(env, None, s.warning)
    _contains(env, s.error, "newer than the root module asks for")
    return unittest.end(env)

def _off_level_is_silent_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("1.0.0", is_root = True), _req("1.1.0")], "off")
    asserts.equals(env, "1.1.0", s.request.version)
    asserts.equals(env, None, s.warning)
    asserts.equals(env, None, s.error)
    return unittest.end(env)

def _settings_tag_is_named_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("1.0.0", is_root = True), _req("1.1.0")], settings = "flutter_pub.settings")
    _contains(env, s.warning, "flutter_pub.settings(check_direct_dependencies = \"off\")")
    return unittest.end(env)

def _digest_conflict_is_an_error_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [
        _req("1.0.0", where = "a", sha256 = "x", refresh = "GET a"),
        _req("1.0.0", where = "b", sha256 = "y", refresh = "GET b"),
    ], "off")
    asserts.equals(env, None, s.request)
    _contains(env, s.error, "Package \"p\" 1.0.0 has conflicting sha256 digests", "x, from a", "y, from b", "  GET a", "  GET b")
    return unittest.end(env)

def _digest_conflict_at_a_losing_version_is_an_error_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("1.0.0", sha256 = "x"), _req("1.0.0", sha256 = "y"), _req("2.0.0")])
    _contains(env, s.error, "conflicting sha256 digests")
    return unittest.end(env)

def _registry_conflict_is_an_error_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("1.0.0", where = "a"), _req("1.0.0", where = "b", url = "https://other")])
    _contains(env, s.error, "different registries", "https://other, from b")
    return unittest.end(env)

def _prerelease_orders_below_release_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("2.0.0-dev.1"), _req("2.0.0"), _req("1.99.0")])
    asserts.equals(env, "2.0.0", s.request.version)
    return unittest.end(env)

def _higher_build_raises_root_test_impl(ctx):
    env = unittest.begin(ctx)
    s = select_pub_version("p", [_req("0.8.12+18", is_root = True), _req("0.8.12+20")])
    asserts.equals(env, "0.8.12+20", s.request.version)
    _contains(env, s.warning, "Package \"p\" is built at 0.8.12+20, newer than the root module asks for")
    return unittest.end(env)

# ---- root-only statements ----

def _module(name, is_root = False, settings = [], packages = [], locks = []):
    return struct(name = name, is_root = is_root, tags = struct(settings = settings, package = packages, from_lock = locks))

def _settings_default_to_warning_test_impl(ctx):
    env = unittest.begin(ctx)
    s = root_only_settings([_module("root", is_root = True), _module("dep")])
    asserts.equals(env, "warning", s.check)
    asserts.equals(env, None, s.error)
    return unittest.end(env)

def _root_settings_apply_test_impl(ctx):
    env = unittest.begin(ctx)
    s = root_only_settings([_module(
        "root",
        is_root = True,
        settings = [struct(check_direct_dependencies = "error")],
        packages = [struct(name = "a", ignore_hook = True), struct(name = "b", ignore_hook = False)],
        locks = [struct(ignore_hooks = ["c"])],
    )])
    asserts.equals(env, "error", s.check)
    asserts.equals(env, {"a": True, "c": True}, s.ignore_hooks)
    return unittest.end(env)

def _dependency_settings_fail_test_impl(ctx):
    env = unittest.begin(ctx)
    s = root_only_settings([_module("root", is_root = True), _module("dep", settings = [struct(check_direct_dependencies = "off")])])
    _contains(env, s.error, "Module `dep` uses `pub.settings`, which only the root module may use")
    return unittest.end(env)

def _two_root_settings_fail_test_impl(ctx):
    env = unittest.begin(ctx)
    tag = struct(check_direct_dependencies = "off")
    s = root_only_settings([_module("root", is_root = True, settings = [tag, tag])])
    _contains(env, s.error, "uses `pub.settings` 2 times")
    return unittest.end(env)

def _dependency_ignore_hooks_fail_test_impl(ctx):
    env = unittest.begin(ctx)
    s = root_only_settings([
        _module("root", is_root = True),
        _module("dep", packages = [struct(name = "a", ignore_hook = True)], locks = [struct(ignore_hooks = ["b"])]),
    ])
    _contains(env, s.error, "Module `dep` ignores the build hooks of `a`, `b`, which only the root module may do")
    return unittest.end(env)

_settings_default_to_warning_test = unittest.make(_settings_default_to_warning_test_impl)
_root_settings_apply_test = unittest.make(_root_settings_apply_test_impl)
_dependency_settings_fail_test = unittest.make(_dependency_settings_fail_test_impl)
_two_root_settings_fail_test = unittest.make(_two_root_settings_fail_test_impl)
_dependency_ignore_hooks_fail_test = unittest.make(_dependency_ignore_hooks_fail_test_impl)
_highest_wins_test = unittest.make(_highest_wins_test_impl)
_first_at_highest_wins_test = unittest.make(_first_at_highest_wins_test_impl)
_raising_a_dependency_is_silent_test = unittest.make(_raising_a_dependency_is_silent_test_impl)
_raised_root_warns_test = unittest.make(_raised_root_warns_test_impl)
_raised_root_lock_gives_its_command_test = unittest.make(_raised_root_lock_gives_its_command_test_impl)
_error_level_fails_test = unittest.make(_error_level_fails_test_impl)
_off_level_is_silent_test = unittest.make(_off_level_is_silent_test_impl)
_settings_tag_is_named_test = unittest.make(_settings_tag_is_named_test_impl)
_digest_conflict_is_an_error_test = unittest.make(_digest_conflict_is_an_error_test_impl)
_digest_conflict_at_a_losing_version_is_an_error_test = unittest.make(_digest_conflict_at_a_losing_version_is_an_error_test_impl)
_registry_conflict_is_an_error_test = unittest.make(_registry_conflict_is_an_error_test_impl)
_prerelease_orders_below_release_test = unittest.make(_prerelease_orders_below_release_test_impl)
_higher_build_raises_root_test = unittest.make(_higher_build_raises_root_test_impl)

def pub_versions_test_suite(name):
    small_unittest_suite(
        name,
        _highest_wins_test,
        _first_at_highest_wins_test,
        _raising_a_dependency_is_silent_test,
        _raised_root_warns_test,
        _raised_root_lock_gives_its_command_test,
        _error_level_fails_test,
        _off_level_is_silent_test,
        _settings_tag_is_named_test,
        _digest_conflict_is_an_error_test,
        _digest_conflict_at_a_losing_version_is_an_error_test,
        _registry_conflict_is_an_error_test,
        _prerelease_orders_below_release_test,
        _higher_build_raises_root_test,
        _settings_default_to_warning_test,
        _root_settings_apply_test,
        _dependency_settings_fail_test,
        _two_root_settings_fail_test,
        _dependency_ignore_hooks_fail_test,
    )
