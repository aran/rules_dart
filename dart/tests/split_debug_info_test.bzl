"""Tests that `//dart:split_debug_info` declares the file it makes the compiler write.

On, an `exe` or `aot-snapshot` compile is told to write its debugging
information to `<name>.symbols`, which is in the `debug_info` output group. Off,
and in the `kernel` mode, nothing about it appears. The run tests in
`//dart/tests/split_debug_info_fixture` check the programs themselves.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_SETTING = str(Label("//dart:split_debug_info"))

def _impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    symbols = [f.basename for f in target[OutputGroupInfo].debug_info.to_list()]
    name = target.label.name
    asserts.equals(env, [name + ".symbols"] if ctx.attr.expect else [], symbols, "debug_info")
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartCompile"]
    flags = [a for c in compiles for a in c.argv if a.startswith("--save-debugging-info")]
    if ctx.attr.expect:
        asserts.equals(env, 1, len(flags), "--save-debugging-info in %s" % [c.argv for c in compiles])
        asserts.true(env, flags[0].endswith("/%s.symbols" % name), flags[0])
    else:
        asserts.equals(env, [], flags, "--save-debugging-info")
    return analysistest.end(env)

def _make(on, expect):
    return analysistest.make(
        _impl,
        attrs = {"expect": attr.bool(default = expect)},
        config_settings = {_SETTING: on},
    )

_split_test = _make(True, True)
_whole_test = _make(False, False)
_split_kernel_test = _make(True, False)

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "--@rules_dart//dart:split_debug_info")
    return analysistest.end(env)

refused_flag_test = analysistest.make(_refused_impl, expect_failure = True)

def split_debug_info_args_suite(name, exe, aot, kernel):
    """Declares the analysis tests of the declared output and the flag passed.

    Args:
      name: Name of the generated `test_suite`.
      exe: A `dart_binary` in the `exe` mode.
      aot: A `dart_binary` in the `aot-snapshot` mode.
      kernel: A `dart_binary` in the `kernel` mode.
    """
    tests = []
    for label, rule, target in [
        ("exe_split", _split_test, exe),
        ("exe_whole", _whole_test, exe),
        ("aot_split", _split_test, aot),
        ("aot_whole", _whole_test, aot),
        ("kernel", _split_kernel_test, kernel),
    ]:
        test_name = "%s_%s" % (name, label)
        rule(name = test_name, size = "small", target_under_test = target)
        tests.append(test_name)
    native.test_suite(name = name, tests = tests)
