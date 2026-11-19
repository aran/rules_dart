"""Unit tests for the tags declaring Dart SDKs, and the toolchains generated for them."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/private:custom_sdks.bzl", "custom_sdks", "sdk_name_error")

# buildifier: disable=bzl-visibility
load("//dart/private:toolchain_selection.bzl", "MINIMUM_SDK_VERSION", "aot_snapshot_needs_runtime", "newest_version", "sdk_too_old_error")

# buildifier: disable=bzl-visibility
load("//dart/private:toolchains_repo.bzl", "CROSS_TARGETS", "PLATFORMS", "cross_pair", "host_toolchains_build_content", "toolchains_build_content")
load(":small_suite.bzl", "small_unittest_suite")

def _module(name = "root", is_root = True, release = [], custom_sdk = [], checkout = [], use_sdk = []):
    return struct(
        name = name,
        is_root = is_root,
        tags = struct(release = release, custom_sdk = custom_sdk, checkout = checkout, use_sdk = use_sdk),
    )

def _release(name = "next", dart_version = "3.15.0", sdk_sha256 = {}, cross_tools_sha256 = {}):
    return struct(name = name, dart_version = dart_version, sdk_sha256 = sdk_sha256, cross_tools_sha256 = cross_tools_sha256)

def _custom(name = "fork", sdk = None, source = None, cross_tools = {}):
    return struct(name = name, sdk = sdk or {"linux-x64": Label("@fork_linux//:version")}, source = source, cross_tools = cross_tools)

def _checkout(name = "local", checkout = None, cross_tools = {}):
    return struct(name = name, checkout = checkout, cross_tools = cross_tools)

def _use(name):
    return struct(name = name)

def _parts(sdk, version):
    """What an SDK with every part in repositories named as the extension names them is made of."""
    return {
        "version": version,
        "hosts": {p: {"repo": "%s_%s" % (sdk, p)} for p in PLATFORMS.keys()},
        "cross": {
            cross_pair(p, t): {"repo": "%s_%s_cross_%s" % (sdk, p, t)}
            for p, targets in CROSS_TARGETS.items()
            for t in targets
        },
        "tools": {"kernel": {"repo": sdk + "_kernel_source"}, "analyzer": {"repo": sdk + "_analyzer_source"}},
    }

def _plan(*modules):
    return custom_sdks(list(modules), ["dart"], "dart")

def _refused(env, result, *fragments):
    asserts.true(env, result.error != None, "expected a refusal")
    for fragment in fragments:
        asserts.true(env, fragment in result.error, "expected {} in:\n{}".format(repr(fragment), result.error))

def _each_form_is_declared_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _plan(_module(
        release = [_release()],
        custom_sdk = [_custom(source = Label("@fork_source//:DEPS"))],
        checkout = [_checkout()],
        use_sdk = [_use("local")],
    ))
    asserts.equals(env, None, result.error)
    asserts.equals(env, "local", result.use)
    asserts.equals(env, {"next": "release", "fork": "custom_sdk", "local": "checkout"}, {n: s.kind for n, s in result.sdks.items()})
    return unittest.end(env)

def _the_default_release_can_be_chosen_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "dart", _plan(_module(use_sdk = [_use("dart")])).use)
    asserts.equals(env, None, _plan(_module()).use)
    return unittest.end(env)

def _only_the_root_declares_or_chooses_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(env, _plan(_module(name = "lib", is_root = False, checkout = [_checkout()])), "module lib", "Only the root module")
    _refused(env, _plan(_module(name = "lib", is_root = False, use_sdk = [_use("dart")])), "module lib", "Only the root module")
    return unittest.end(env)

def _names_are_checked_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(env, _plan(_module(release = [_release(name = "dart")])), "takes the name of the release", "dart.use_sdk")
    _refused(env, _plan(_module(release = [_release(name = "a-b")])), "letters, digits and underscores")
    _refused(env, _plan(_module(release = [_release(name = "x")], checkout = [_checkout(name = "x")])), '"x" is declared twice', "dart.release()", "dart.checkout()")
    _refused(
        env,
        custom_sdks([_module(release = [_release(name = "x")])], ["dart", "x"], "dart"),
        'dart.toolchain(name = "x")',
    )
    return unittest.end(env)

def _the_choice_is_checked_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(env, _plan(_module(release = [_release()], use_sdk = [_use("nope")])), '"nope"', "dart, next")
    _refused(env, _plan(_module(use_sdk = [_use("dart"), _use("dart")])), "two Dart SDKs")
    return unittest.end(env)

def _attributes_are_checked_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(env, _plan(_module(release = [_release(dart_version = "latest")])), "`dart_version` latest")
    _refused(env, _plan(_module(release = [_release(sdk_sha256 = {"plan9": "x"})])), "plan9", "macos-arm64")
    _refused(env, _plan(_module(release = [_release(cross_tools_sha256 = {"gen_snapshot": "x"})])), "`cross_tools_sha256`", "gen_snapshot")
    _refused(env, _plan(_module(custom_sdk = [_custom(sdk = {"plan9": Label("@x//:version")})])), "plan9")
    _refused(env, _plan(_module(custom_sdk = [_custom(sdk = {"linux-x64": Label("@x//:bin/dart")})])), "`version` file")
    _refused(env, _plan(_module(custom_sdk = [_custom(source = Label("@x//:README"))])), "`DEPS` file")
    _refused(env, _plan(_module(checkout = [_checkout(checkout = Label("@x//:README"))])), "`DEPS` file")

    _refused(env, _plan(_module(custom_sdk = [_custom(cross_tools = {"gen_snapshot": Label("@x//:y")})])), "`cross_tools`", "gen_snapshot")
    _refused(env, _plan(_module(checkout = [_checkout(cross_tools = {"dartaotruntime": Label("@x//:y")})])), "`cross_tools`", "dartaotruntime")
    asserts.equals(env, None, _plan(_module(checkout = [_checkout(cross_tools = {"dartaotruntime_linux_x64": Label("@x//:y")})])).error)

    # The file may sit below the repository's root.
    asserts.equals(env, None, _plan(_module(custom_sdk = [_custom(sdk = {"linux-x64": Label("@x//out/dart-sdk:version")})])).error)
    return unittest.end(env)

def _prereleases_sort_before_their_release_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.15.0", newest_version(["3.15.0-1.0.dev", "3.15.0", "3.15.0-2.0.beta"]))
    asserts.equals(env, "3.15.0-2.0.beta", newest_version(["3.15.0-2.0.beta", "3.15.0-1.9.beta", "3.14.9"]))
    asserts.equals(env, "3.15.0-10.0.dev", newest_version(["3.15.0-9.0.dev", "3.15.0-10.0.dev"]))
    asserts.equals(env, "3.15.0-edge", newest_version(["3.15.0-edge", "3.15.0-1.0.dev"]))
    return unittest.end(env)

def _requests_are_checked_against_the_sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, sdk_too_old_error("local", "3.15.0-edge", {"a": "3.14.1"}))
    error = sdk_too_old_error("local", "3.14.0", {"a": "3.14.1", "b": "3.13.0", "c": "3.15.0"})
    for fragment in ['Dart SDK "local" is 3.14.0', "a requests 3.14.1", "c requests 3.15.0", "at least 3.15.0", "dart.use_sdk", "--@rules_dart//dart:sdk"]:
        asserts.true(env, fragment in error, error)
    asserts.false(env, "b requests" in error, error)
    return unittest.end(env)

def _sdks_below_the_minimum_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    for version in ["3.12.2", "3.9.4", "2.19.6", "3.12.9-1.0.dev"]:
        error = sdk_too_old_error("old", version, {})
        asserts.true(env, error != None, version)
        for fragment in ['Dart SDK "old" is ' + version, "at least Dart " + MINIMUM_SDK_VERSION, "dart.use_sdk", "--@rules_dart//dart:sdk"]:
            asserts.true(env, fragment in error, error)

    # A prerelease of the minimum has its language version.
    for version in [MINIMUM_SDK_VERSION, "3.13.0-1.0.dev", "3.13.7", "3.14.1"]:
        asserts.equals(env, None, sdk_too_old_error("new", version, {}), version)
    return unittest.end(env)

def _contains(env, text, fragment):
    asserts.true(env, fragment in text, "expected {} in the generated BUILD file".format(repr(fragment)))

def _toolchains_follow_the_choice_test_impl(ctx):
    env = unittest.begin(ctx)
    build = toolchains_build_content(
        {"dart": _parts("dart", "3.14.1"), "next": _parts("next", "3.15.0"), "local": _parts("local", "")},
        "local",
        {"next": "too old"},
    )

    # Unset, the flag means the root module's choice, and only that SDK's.
    chosen = build[build.index('name = "local-uses"'):build.index('name = "next-chosen"')]
    _contains(env, chosen, '":flag_unset": "@rules_dart//dart/private:sdk_always"')
    other = build[build.index('name = "dart-uses"'):build.index('name = "local-chosen"')]
    asserts.false(env, "flag_unset" in other, other)

    # Every SDK's targets start with its name.
    _contains(env, build, 'name = "dart-macos-arm64_toolchain"')
    _contains(env, build, 'name = "local-macos-arm64_toolchain"')
    _contains(env, build, 'toolchain = "@local_macos-arm64//:dart_toolchain"')
    _contains(env, build, 'name = "local-macos-arm64_cross_linux-x64_toolchain"')

    # A release's toolchains are here, over the repositories of its files;
    # another SDK has a repository for each pair, which alone knows its version.
    _contains(env, build, 'toolchain = "@local_macos-arm64_cross_linux-x64//:dart_toolchain_cross_linux-x64"')
    _contains(env, build, 'toolchain = ":dart-macos-arm64_cross_linux-x64_sdk"')
    _contains(env, build, 'dart = "@dart_macos-arm64//:bin/dart"')
    _contains(env, build, 'dart = "@dart_windows-x64//:bin/dart.exe"')
    _contains(env, build, 'sdk_cache = "@dart_macos-arm64_cross_linux-x64//:sdk_cache"')

    # Outside the repositories of its files, a toolchain still says what they are.
    _contains(env, build, 'package_metadata = ["@dart_macos-arm64//:package_metadata"]')
    _contains(env, build, 'package_metadata = ["@dart_macos-arm64//:package_metadata","@dart_macos-arm64_cross_linux-x64//:package_metadata"]')

    # Only the SDK's files say a checkout's version: its tools' toolchains are
    # in the repository reading them.
    _contains(env, build, 'toolchain = "@local_tools//:outline"')
    _contains(env, build, 'toolchain = "@local_tools//:analyzer"')
    _contains(env, build, '"@next_kernel_source//:outline_tool"')

    # An SDK that cannot serve the build says so when it is used.
    _contains(env, build, 'name = "next-unavailable"')
    _contains(env, build, 'message = "too old"')
    _contains(env, build, 'toolchain = ":next-unavailable"')

    # A name no tag declares lists those that are.
    _contains(env, build, "The declared SDKs are: dart, local, next.")
    return unittest.end(env)

def _no_sdk_name_collides_test_impl(ctx):
    env = unittest.begin(ctx)

    # Names built to meet the repository's own targets, and each other's.
    sdks = {name: _parts(name, "3.14.1") for name in [
        "dart",
        "undeclared_sdk",
        "flag_unset",
        "uses_dart",
        "uses_a",
        "a",
        "a__outline",
        "a__b",
        "flag_is_a",
    ]}
    build = toolchains_build_content(sdks, "undeclared_sdk", {name: "no" for name in sdks})
    names = [part.partition('"')[0] for part in build.split('\n    name = "')[1:]]
    asserts.true(env, len(names) > len(sdks), "no targets found")
    asserts.equals(env, sorted(names), sorted({name: None for name in names}.keys()))
    return unittest.end(env)

def _toolchain_names(build):
    return [part.partition('"')[0] for part in build.split('\ntoolchain(\n    name = "')[1:]]

def _what_an_sdk_lacks_fails_when_used_test_impl(ctx):
    env = unittest.begin(ctx)
    parts = _parts("next", "3.15.0")
    parts["hosts"]["linux-x64"] = {"error": "no linux archive"}
    parts["cross"][cross_pair("macos-arm64", "linux-x64")] = {
        "repo": "next_macos-arm64_cross_linux-x64",
        "missing": {"dartaotruntime": "no runtime"},
    }
    parts["cross"][cross_pair("macos-arm64", "linux-arm64")] = {"missing": {"gen_snapshot": "no compiler", "dartaotruntime": "no runtime"}}
    parts["tools"]["kernel"] = {"error": "no source"}
    build = toolchains_build_content({"dart": _parts("dart", "3.14.1"), "next": parts}, "dart", {})

    # A toolchain matching a platform the SDK lacks would end Bazel's search
    # there, so nothing is registered for that host or its cross compiles, and
    # the pairs missing a tool are not offered to other machines either.
    names = _toolchain_names(build)
    asserts.false(env, "next-linux-x64_toolchain" in names, names)
    asserts.false(env, "next-linux-x64_exec_tools_toolchain" in names, names)
    asserts.false(env, "next-linux-x64_cross_linux-arm64_toolchain" in names, names)
    asserts.false(env, "next-macos-arm64_cross_linux-x64_toolchain" in names, names)
    asserts.false(env, "next-macos-arm64_cross_linux-arm64_toolchain" in names, names)
    asserts.true(env, "next-macos-arm64_toolchain" in names, names)
    asserts.true(env, "next-macos-arm64_cross_linux-riscv64_toolchain" in names, names)
    _contains(env, build, 'name = "next-kernel_unavailable",\n    message = "no source"')
    _contains(env, build, '"@rules_dart//dart:is_outline_kernel": ":next-kernel_unavailable"')

    # On the machine Bazel runs on, the last platform tried, a host the SDK
    # lacks stops the build with the reason.
    sdks = {"dart": _parts("dart", "3.14.1"), "next": parts}
    here = host_toolchains_build_content("linux-x64", None, sdks, {})
    _contains(env, here, 'name = "next-unserved_host",\n    message = "no linux archive"')
    _contains(env, here, 'target_settings = ["@dart_toolchains//:next-uses"]')
    _contains(env, here, 'exec_compatible_with = ["@platforms//os:linux","@platforms//cpu:x86_64"]')
    asserts.equals(
        env,
        ["next-unserved_host_exec_tools_toolchain", "next-unserved_host_toolchain"],
        sorted(_toolchain_names(here)),
    )

    # A pair missing a tool is offered there too, and left to the compile that
    # needs that tool.
    here = host_toolchains_build_content("macos-arm64", None, sdks, {})
    asserts.equals(
        env,
        ["next-macos-arm64_cross_linux-arm64_toolchain", "next-macos-arm64_cross_linux-x64_toolchain"],
        sorted(_toolchain_names(here)),
    )
    _contains(env, here, 'missing_cross_tools = {"dartaotruntime":"no runtime"}')
    pair = here[here.index('name = "next-macos-arm64_cross_linux-arm64_sdk"'):]
    pair = pair[:pair.index("\n)\n")]
    asserts.false(env, "sdk_cache" in pair, pair)

    # Where the SDK serves everything, this machine adds nothing.
    asserts.equals(env, [], _toolchain_names(host_toolchains_build_content("macos-x64", None, sdks, {})))
    return unittest.end(env)

def _a_checkout_serves_only_this_machine_test_impl(ctx):
    env = unittest.begin(ctx)
    parts = _parts("local", "")
    parts["host_only"] = True
    sdks = {"dart": _parts("dart", "3.14.1"), "local": parts}

    # Which machine that is is known when repositories are fetched, not when
    # the toolchains every machine shares are written.
    names = _toolchain_names(toolchains_build_content(sdks, "dart", {}))
    asserts.equals(env, ["local-analyzer_toolchain", "local-outline_toolchain"], sorted([n for n in names if n.startswith("local-")]))
    here = host_toolchains_build_content("macos-arm64", None, sdks, {})
    asserts.equals(
        env,
        sorted([
            "local-macos-arm64_toolchain",
            "local-macos-arm64_exec_tools_toolchain",
        ] + ["local-macos-arm64_cross_%s_toolchain" % t for t in CROSS_TARGETS["macos-arm64"]]),
        sorted(_toolchain_names(here)),
    )
    _contains(env, here, 'toolchain = "@local_macos-arm64//:dart_toolchain"')
    _contains(env, here, 'toolchain = "@local_macos-arm64_cross_linux-x64//:dart_toolchain_cross_linux-x64"')

    # An SDK no build can use says so from the shared toolchains, on any platform.
    build = toolchains_build_content(sdks, "dart", {"local": "too old"})
    _contains(env, build, 'name = "local-macos-x64_toolchain"')
    asserts.equals(env, [], _toolchain_names(host_toolchains_build_content("macos-arm64", None, sdks, {"local": "too old"})))
    return unittest.end(env)

def _toolchain_names_are_checked_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, sdk_name_error("dart", "tag"))
    asserts.equals(env, None, sdk_name_error("Next_2", "tag"))
    for name in ["a-b", "", "2a", "_a", "a.b"]:
        error = sdk_name_error(name, "tag")
        asserts.true(env, error and "letters, digits and underscores" in error, name)
    return unittest.end(env)

def _aot_snapshot_runtime_follows_the_version_test_impl(ctx):
    env = unittest.begin(ctx)

    # A main-channel build of the release the change landed in does not say
    # which side of the change it is on: it has no build number.
    for version in ["3.13.0", "3.14.1", "3.14.0-edge.abc", "3.15.0-80.0.dev", "3.15.0-edge", "3.15.0-edge.abc", "not a version"]:
        asserts.true(env, aot_snapshot_needs_runtime(version), version)
    for version in ["3.15.0-81.0.dev", "3.15.0-148.0.dev", "3.15.0-1.0.beta", "3.15.0", "3.16.0", "3.16.0-edge.abc"]:
        asserts.equals(env, version == "3.15.0-1.0.beta", aot_snapshot_needs_runtime(version), version)
    return unittest.end(env)

_lacks_test = unittest.make(_what_an_sdk_lacks_fails_when_used_test_impl)
_checkout_host_test = unittest.make(_a_checkout_serves_only_this_machine_test_impl)
_toolchain_names_test = unittest.make(_toolchain_names_are_checked_test_impl)
_aot_runtime_test = unittest.make(_aot_snapshot_runtime_follows_the_version_test_impl)
_minimum_test = unittest.make(_sdks_below_the_minimum_are_refused_test_impl)
_t0_test = unittest.make(_each_form_is_declared_test_impl)
_t1_test = unittest.make(_the_default_release_can_be_chosen_test_impl)
_t2_test = unittest.make(_only_the_root_declares_or_chooses_test_impl)
_t3_test = unittest.make(_names_are_checked_test_impl)
_t4_test = unittest.make(_the_choice_is_checked_test_impl)
_t5_test = unittest.make(_attributes_are_checked_test_impl)
_t6_test = unittest.make(_prereleases_sort_before_their_release_test_impl)
_t7_test = unittest.make(_requests_are_checked_against_the_sdk_test_impl)
_t8_test = unittest.make(_toolchains_follow_the_choice_test_impl)
_t9_test = unittest.make(_no_sdk_name_collides_test_impl)

def custom_sdks_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _minimum_test, _lacks_test, _checkout_host_test, _toolchain_names_test, _aot_runtime_test)
