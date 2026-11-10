"""Unit tests for the Dart toolchain version selection in the `dart` extension."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/private:toolchain_selection.bzl", "select_toolchain_version")
load(":small_suite.bzl", "small_unittest_suite")

def _root(version, allow_upgrade = False, module = "root"):
    return struct(module = module, version = version, is_root = True, allow_upgrade = allow_upgrade)

def _dep(version, module = "dep"):
    return struct(module = module, version = version, is_root = False, allow_upgrade = False)

def _contains(env, text, *fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "expected {} in:\n{}".format(repr(fragment), text))

def _select(requests):
    return select_toolchain_version("dart", requests)

# ---- no root request: the highest request wins ----

def _no_root_highest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_dep("3.9.0", "a"), _dep("3.13.4", "b"), _dep("3.10.1", "c")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _no_root_single_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_dep("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

# ---- a root request, flag off (the default): used exactly ----

def _root_alone_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _root_equal_to_dependencies_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.13.4"), _dep("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _root_above_dependencies_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.13.4"), _dep("3.12.2"), _dep("3.9.0", "other")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _root_below_dependency_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.12.2"), _dep("3.13.4", "newer_dep")])
    asserts.equals(env, None, selection.version)
    _contains(
        env,
        selection.error,
        "Dart toolchain \"dart\"",
        "the root module pins 3.12.2",
        "newer_dep requests 3.13.4",
        # Fix one: raise the pin.
        "dart_version",
        "at least 3.13.4",
        # Fix two: allow the upgrade.
        "allow_upgrade_by_dependencies = True",
    )
    return unittest.end(env)

def _root_below_names_every_newer_dependency_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([
        _root("3.12.2"),
        _dep("3.13.4", "first"),
        _dep("3.12.2", "equal"),
        _dep("3.9.0", "older"),
        _dep("3.14.1", "second"),
    ])
    _contains(
        env,
        selection.error,
        "first requests 3.13.4",
        "second requests 3.14.1",
        # The pin to raise to is the highest of them.
        "at least 3.14.1",
    )
    asserts.false(env, "equal requests" in selection.error)
    asserts.false(env, "older requests" in selection.error)
    return unittest.end(env)

def _versions_compare_numerically_test_impl(ctx):
    env = unittest.begin(ctx)

    # 3.9.0 < 3.10.0 by number, though not as strings.
    selection = _select([_root("3.9.0"), _dep("3.10.0")])
    asserts.equals(env, None, selection.version)
    _contains(env, selection.error, "dep requests 3.10.0")
    selection = _select([_root("3.10.0"), _dep("3.9.0")])
    asserts.equals(env, "3.10.0", selection.version)
    return unittest.end(env)

# ---- a root request, flag on: the highest of all, the root's included ----

def _allowed_root_below_dependency_upgrades_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.12.2", allow_upgrade = True), _dep("3.13.4"), _dep("3.10.0", "older")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _allowed_root_equal_to_dependencies_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.13.4", allow_upgrade = True), _dep("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _allowed_root_above_dependencies_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.14.0", allow_upgrade = True), _dep("3.13.4")])
    asserts.equals(env, "3.14.0", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _allowed_root_alone_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.13.4", allow_upgrade = True)])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

# ---- the root requests one name twice ----

def _two_root_requests_fail_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.12.2"), _root("3.13.4"), _dep("3.10.0")])
    asserts.equals(env, None, selection.version)
    _contains(
        env,
        selection.error,
        "Dart toolchain \"dart\"",
        "root module requests",
        "3.12.2",
        "3.13.4",
        "one root request",
    )
    return unittest.end(env)

def _two_equal_root_requests_fail_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.13.4"), _root("3.13.4")])
    asserts.equals(env, None, selection.version)
    _contains(env, selection.error, "root module requests", "one root request")
    return unittest.end(env)

# ---- a non-root module sets the flag ----

def _dependency_setting_the_flag_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    dep = struct(module = "greedy", version = "3.13.4", is_root = False, allow_upgrade = True)
    for requests in ([dep], [_root("3.13.4"), dep]):
        selection = _select(requests)
        asserts.equals(env, None, selection.version)
        _contains(
            env,
            selection.error,
            "Only the root module may set allow_upgrade_by_dependencies",
            "greedy",
        )
    return unittest.end(env)

_no_root_highest_wins_test = unittest.make(_no_root_highest_wins_test_impl)
_no_root_single_request_test = unittest.make(_no_root_single_request_test_impl)
_root_alone_test = unittest.make(_root_alone_test_impl)
_root_equal_to_dependencies_test = unittest.make(_root_equal_to_dependencies_test_impl)
_root_above_dependencies_test = unittest.make(_root_above_dependencies_test_impl)
_root_below_dependency_fails_test = unittest.make(_root_below_dependency_fails_test_impl)
_root_below_names_every_newer_dependency_test = unittest.make(_root_below_names_every_newer_dependency_test_impl)
_versions_compare_numerically_test = unittest.make(_versions_compare_numerically_test_impl)
_allowed_root_below_dependency_upgrades_test = unittest.make(_allowed_root_below_dependency_upgrades_test_impl)
_allowed_root_equal_to_dependencies_test = unittest.make(_allowed_root_equal_to_dependencies_test_impl)
_allowed_root_above_dependencies_test = unittest.make(_allowed_root_above_dependencies_test_impl)
_allowed_root_alone_test = unittest.make(_allowed_root_alone_test_impl)
_two_root_requests_fail_test = unittest.make(_two_root_requests_fail_test_impl)
_two_equal_root_requests_fail_test = unittest.make(_two_equal_root_requests_fail_test_impl)
_dependency_setting_the_flag_fails_test = unittest.make(_dependency_setting_the_flag_fails_test_impl)

def toolchain_selection_test_suite(name):
    small_unittest_suite(
        name,
        _no_root_highest_wins_test,
        _no_root_single_request_test,
        _root_alone_test,
        _root_equal_to_dependencies_test,
        _root_above_dependencies_test,
        _root_below_dependency_fails_test,
        _root_below_names_every_newer_dependency_test,
        _versions_compare_numerically_test,
        _allowed_root_below_dependency_upgrades_test,
        _allowed_root_equal_to_dependencies_test,
        _allowed_root_above_dependencies_test,
        _allowed_root_alone_test,
        _two_root_requests_fail_test,
        _two_equal_root_requests_fail_test,
        _dependency_setting_the_flag_fails_test,
    )
