"""Tests that `//dart:track_creation_locations` reaches every VM kernel compile.

The setting has to be the same for each module of a program and for its
entrypoint, so it is one flag, passed to every compile or to none. These pin the
arguments of the compiles a target makes itself: its own module, the entrypoint
compiled against modules, and the whole-program compile of `dart_binary`. The
modules of its dependencies come from an aspect, whose actions an analysis test
cannot see; the run tests in `//dart/tests/track_creation_fixture` cover them,
since a program whose tracked class was compiled without the setting records no
locations.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_FLAG = "--track-creation-locations"
_SETTING = str(Label("//dart:track_creation_locations"))

# The modular path's compiles, whatever the command line says: under
# `--@rules_dart//dart:modular_kernel=false` a `dart_test` compiles as
# `dart_binary` does, which the `dart_binary` tests cover.
_MODULAR_KERNEL = str(Label("//dart:modular_kernel"))

def _args_test_impl(ctx):
    env = analysistest.begin(ctx)
    seen = []
    for action in analysistest.target_actions(env):
        if action.mnemonic not in ctx.attr.mnemonics:
            continue
        seen.append(action.mnemonic)
        asserts.equals(
            env,
            ctx.attr.expect,
            _FLAG in action.argv,
            "%s %s %s: %s" % (
                action.mnemonic,
                "is missing" if ctx.attr.expect else "must not carry",
                _FLAG,
                action.argv,
            ),
        )
        if not ctx.attr.expect:
            # Off, nothing about the transform appears, so command lines and
            # cache keys are what they were without the flag.
            asserts.equals(
                env,
                [],
                [a for a in action.argv if a.startswith("-") and "track" in a],
                "%s mentions tracking with the flag off: %s" % (action.mnemonic, action.argv),
            )
    asserts.equals(env, sorted(ctx.attr.mnemonics), sorted(depset(seen).to_list()), "actions seen")
    return analysistest.end(env)

def _args_test(expect):
    return analysistest.make(
        _args_test_impl,
        attrs = {
            "expect": attr.bool(default = expect),
            "mnemonics": attr.string_list(mandatory = True),
        },
        config_settings = {_SETTING: expect, _MODULAR_KERNEL: True},
    )

tracked_args_test = _args_test(True)
untracked_args_test = _args_test(False)

def track_creation_locations_args_suite(name, test, binary):
    """Declares the analysis tests of the compile arguments.

    Args:
      name: Name of the generated `test_suite`.
      test: A `dart_test` target (the modular path).
      binary: A `dart_binary` target.
    """
    tests = []
    for label, rules, mnemonics, target in [
        ("dart_test", (tracked_args_test, untracked_args_test), ["DartModule", "DartEntryKernel"], test),
        ("dart_binary", (tracked_args_test, untracked_args_test), ["DartKernel"], binary),
    ]:
        for state, rule in zip(["on", "off"], rules):
            test_name = "%s_%s_%s" % (name, label, state)
            rule(
                name = test_name,
                size = "small",
                mnemonics = mnemonics,
                target_under_test = target,
            )
            tests.append(test_name)
    native.test_suite(name = name, tests = tests)
