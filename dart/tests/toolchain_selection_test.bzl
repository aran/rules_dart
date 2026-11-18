"""Unit tests for the Dart toolchain version selection in the `dart` extension."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/private:toolchain_selection.bzl", "named_toolchain_requests", "newest_version", "select_toolchain_version", "servable_release")
load(":small_suite.bzl", "small_unittest_suite")

def _root(version, allow_upgrade = False, module = "root"):
    return struct(module = module, version = version, is_root = True, allow_upgrade = allow_upgrade)

def _dep(version, module = "dep"):
    return struct(module = module, version = version, is_root = False, allow_upgrade = False)

def _contains(env, text, *fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "expected {} in:\n{}".format(repr(fragment), text))

_NEWEST = "3.14.1"

def _select(requests):
    return select_toolchain_version("dart", requests, _NEWEST)

# ---- no root request: the newest version rules_dart serves ----

def _no_root_newest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_dep("3.9.0", "a"), _dep("3.13.4", "b"), _dep("3.10.1", "c")])
    asserts.equals(env, _NEWEST, selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _no_request_newest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([])
    asserts.equals(env, _NEWEST, selection.version)
    asserts.equals(env, None, selection.error)
    return unittest.end(env)

def _newest_version_ignores_order_test_impl(ctx):
    env = unittest.begin(ctx)
    for versions in [["3.14.0", "3.13.4", "3.9.0"], ["3.9.0", "3.14.0", "3.13.4"], ["3.13.4", "3.9.0", "3.14.0"]]:
        asserts.equals(env, "3.14.0", newest_version(versions), str(versions))
    asserts.equals(env, "3.10.0", newest_version(["3.9.9", "3.10.0"]))
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

def _root_below_dependency_conflicts_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select([_root("3.12.2"), _dep("3.13.4", "newer_dep")])

    # Not an error: the build may use another SDK. The pin stands.
    asserts.equals(env, None, selection.error)
    asserts.equals(env, "3.12.2", selection.version)
    _contains(
        env,
        selection.conflict,
        "Dart toolchain \"dart\"",
        "the root module pins 3.12.2",
        "newer_dep requests 3.13.4",
        # Fix one: raise the pin.
        "dart_version",
        "at least 3.13.4",
        # Fix two: allow the upgrade.
        "allow_upgrade_by_dependencies = True",
        # Fix three: build with another SDK.
        "dart.use_sdk",
        "--@rules_dart//dart:sdk",
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
        selection.conflict,
        "first requests 3.13.4",
        "second requests 3.14.1",
        # The pin to raise to is the highest of them.
        "at least 3.14.1",
    )
    asserts.false(env, "equal requests" in selection.conflict)
    asserts.false(env, "older requests" in selection.conflict)
    return unittest.end(env)

def _versions_compare_numerically_test_impl(ctx):
    env = unittest.begin(ctx)

    # 3.9.0 < 3.10.0 by number, though not as strings.
    selection = _select([_root("3.9.0"), _dep("3.10.0")])
    asserts.equals(env, "3.9.0", selection.version)
    _contains(env, selection.conflict, "dep requests 3.10.0")
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
    selection = _select([_root("3.14.1", allow_upgrade = True), _dep("3.13.4")])
    asserts.equals(env, "3.14.1", selection.version)
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

# ---- what is fetched, and what stops only the builds using the SDK ----

_SERVED = ["3.14.0", "3.14.1"]

def _servable(requests):
    selection = _select(requests)
    if selection.error:
        fail(selection.error)
    return servable_release(selection, _SERVED)

def _a_served_release_is_fetched_as_selected_test_impl(ctx):
    env = unittest.begin(ctx)
    release = _servable([_root("3.14.0"), _dep("3.13.0")])
    asserts.equals(env, "3.14.0", release.version)
    asserts.equals(env, None, release.unavailable)
    return unittest.end(env)

def _a_conflict_stops_only_builds_using_the_sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    release = _servable([_root("3.14.0"), _dep("3.15.0", "newer_dep")])

    # The pin is still what `dart` holds; the pubspec reader is compiled with it.
    asserts.equals(env, "3.14.0", release.version)
    _contains(env, release.unavailable, "newer_dep requests 3.15.0")
    return unittest.end(env)

def _a_request_past_what_is_served_keeps_a_fetchable_release_test_impl(ctx):
    env = unittest.begin(ctx)
    for requests in (
        [_dep("99.0.0")],
        [_root("3.14.0", allow_upgrade = True), _dep("99.0.0")],
    ):
        release = _servable(requests)
        asserts.equals(env, "3.14.1", release.version, str(requests))

        # `sdk_too_old_error` reports it, against this version.
        asserts.equals(env, None, release.unavailable, str(requests))
    return unittest.end(env)

def _an_unserved_pin_stops_only_builds_using_the_sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    release = _servable([_root("3.13.0")])
    asserts.equals(env, "3.14.1", release.version)
    _contains(env, release.unavailable, "does not serve Dart SDK 3.13.0", "It serves: 3.14.0, 3.14.1", "dart.release(")

    # Both reasons, when both hold.
    release = _servable([_root("3.13.0"), _dep("99.0.0", "newer_dep")])
    _contains(env, release.unavailable, "newer_dep requests 99.0.0", "does not serve Dart SDK 3.13.0")
    return unittest.end(env)

_a_served_release_is_fetched_as_selected_test = unittest.make(_a_served_release_is_fetched_as_selected_test_impl)
_a_conflict_stops_only_builds_using_the_sdk_test = unittest.make(_a_conflict_stops_only_builds_using_the_sdk_test_impl)
_a_request_past_what_is_served_keeps_a_fetchable_release_test = unittest.make(_a_request_past_what_is_served_keeps_a_fetchable_release_test_impl)
_an_unserved_pin_stops_only_builds_using_the_sdk_test = unittest.make(_an_unserved_pin_stops_only_builds_using_the_sdk_test_impl)
# ---- a toolchain under another name: dependencies' requests reach it too ----

def _select_named(root):
    return select_toolchain_version("x", named_toolchain_requests([root], {"dep": "3.14.1"}), _NEWEST)

def _named_toolchain_upgrades_when_allowed_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select_named(_root("3.14.0", allow_upgrade = True))
    asserts.equals(env, "3.14.1", selection.version)
    asserts.equals(env, "3.14.0", selection.pinned)
    asserts.equals(env, None, selection.conflict)
    return unittest.end(env)

def _named_toolchain_conflicts_otherwise_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = _select_named(_root("3.14.0"))
    asserts.equals(env, "3.14.0", selection.version)
    _contains(env, selection.conflict, 'Dart toolchain "x"', "dep requests 3.14.1", "allow_upgrade_by_dependencies = True")
    return unittest.end(env)

_named_toolchain_upgrades_when_allowed_test = unittest.make(_named_toolchain_upgrades_when_allowed_test_impl)
_named_toolchain_conflicts_otherwise_test = unittest.make(_named_toolchain_conflicts_otherwise_test_impl)
_no_root_newest_wins_test = unittest.make(_no_root_newest_wins_test_impl)
_no_request_newest_wins_test = unittest.make(_no_request_newest_wins_test_impl)
_newest_version_ignores_order_test = unittest.make(_newest_version_ignores_order_test_impl)
_root_alone_test = unittest.make(_root_alone_test_impl)
_root_equal_to_dependencies_test = unittest.make(_root_equal_to_dependencies_test_impl)
_root_above_dependencies_test = unittest.make(_root_above_dependencies_test_impl)
_root_below_dependency_conflicts_test = unittest.make(_root_below_dependency_conflicts_test_impl)
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
        _no_root_newest_wins_test,
        _no_request_newest_wins_test,
        _newest_version_ignores_order_test,
        _root_alone_test,
        _root_equal_to_dependencies_test,
        _root_above_dependencies_test,
        _root_below_dependency_conflicts_test,
        _a_served_release_is_fetched_as_selected_test,
        _a_conflict_stops_only_builds_using_the_sdk_test,
        _a_request_past_what_is_served_keeps_a_fetchable_release_test,
        _an_unserved_pin_stops_only_builds_using_the_sdk_test,
        _root_below_names_every_newer_dependency_test,
        _versions_compare_numerically_test,
        _allowed_root_below_dependency_upgrades_test,
        _allowed_root_equal_to_dependencies_test,
        _allowed_root_above_dependencies_test,
        _allowed_root_alone_test,
        _two_root_requests_fail_test,
        _two_equal_root_requests_fail_test,
        _dependency_setting_the_flag_fails_test,
        _named_toolchain_upgrades_when_allowed_test,
        _named_toolchain_conflicts_otherwise_test,
    )
