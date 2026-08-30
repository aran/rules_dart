"""Tests that `defines` reach the action which runs the Dart front end.

`-D` values are resolved during constant evaluation, so they take effect only
in the stable kernel action that compiles source. `dart compile` accepts `-D`
on a kernel input while silently ignoring it. Nothing fails, the define just
evaporates, so these tests pin which stage receives the flag with and without
native-assets metadata.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:build_settings.bzl", "dart_define_error")
load("//dart/private:dart_compile.bzl", "defines_stage_error")
load(":small_suite.bzl", "small_unittest_suite")

_DART_KERNEL = "DartKernel"
_DART_COMPILE = "DartCompile"

def _argv_for(env, mnemonic):
    """The argv of the target's action with `mnemonic`, or None if absent."""
    for action in analysistest.target_actions(env):
        if action.mnemonic == mnemonic:
            return action.argv
    return None

def _mnemonics(env):
    return [a.mnemonic for a in analysistest.target_actions(env)]

def _staged_defines_test_impl(ctx):
    # With code assets the front end runs in gen_kernel, so that is where the
    # define has to land. Passing it again to the kernel->exe stage would be a
    # silent no-op, which is exactly how the original bug read as "supported".
    env = analysistest.begin(ctx)
    flag = "-D" + ctx.attr.expected_define
    gen_kernel = _argv_for(env, _DART_KERNEL)
    dart_compile = _argv_for(env, _DART_COMPILE)
    if gen_kernel == None or dart_compile == None:
        asserts.true(
            env,
            False,
            "expected both a %s and a %s action, saw %s" %
            (_DART_KERNEL, _DART_COMPILE, _mnemonics(env)),
        )
        return analysistest.end(env)
    asserts.true(
        env,
        flag in gen_kernel,
        "%s missing from the front-end stage: %s" % (flag, gen_kernel),
    )
    asserts.true(
        env,
        flag not in dart_compile,
        "%s must not be repeated on the kernel->exe stage: %s" % (flag, dart_compile),
    )
    return analysistest.end(env)

staged_defines_test = analysistest.make(
    _staged_defines_test_impl,
    attrs = {"expected_define": attr.string()},
)

def _direct_defines_test_impl(ctx):
    # Without code assets the same stable front end still owns constant
    # evaluation; only the native-assets option is absent.
    env = analysistest.begin(ctx)
    flag = "-D" + ctx.attr.expected_define
    gen_kernel = _argv_for(env, _DART_KERNEL)
    dart_compile = _argv_for(env, _DART_COMPILE)
    if gen_kernel == None or dart_compile == None:
        asserts.true(
            env,
            False,
            "expected both a %s and a %s action, saw %s" %
            (_DART_KERNEL, _DART_COMPILE, _mnemonics(env)),
        )
        return analysistest.end(env)
    asserts.true(
        env,
        flag in gen_kernel,
        "%s missing from the front-end stage: %s" % (flag, gen_kernel),
    )
    asserts.true(
        env,
        flag not in dart_compile,
        "%s must not be repeated on the kernel->exe stage: %s" % (flag, dart_compile),
    )
    return analysistest.end(env)

direct_defines_test = analysistest.make(
    _direct_defines_test_impl,
    attrs = {"expected_define": attr.string()},
)

# --- defines_stage_error ---

def _sound_when_compiling_source_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, defines_stage_error(["A=1"], "package_config.json"))
    return unittest.end(env)

def _sound_when_no_defines_test_impl(ctx):
    # A kernel input is fine on its own; only defines make it a mistake.
    env = unittest.begin(ctx)
    asserts.equals(env, None, defines_stage_error([], None))
    return unittest.end(env)

def _rejects_defines_on_kernel_input_test_impl(ctx):
    env = unittest.begin(ctx)
    err = defines_stage_error(["A=1"], None)
    asserts.true(env, err != None, "defines on a pre-built kernel must be rejected")
    asserts.true(env, "A=1" in err, "the message should name the offending defines: %s" % err)
    return unittest.end(env)

# --- dart_define_error ---

def _accepts_usable_defines_test_impl(ctx):
    # A bare KEY is a key with no value, which the Dart compilers accept, and a
    # value may itself contain `=` — only the first one separates.
    env = unittest.begin(ctx)
    for define in ["KEY=value", "KEY", "KEY=a=b", "KEY=", "KEY=hello world"]:
        asserts.equals(env, None, dart_define_error(define, "test"), "rejected %r" % define)
    return unittest.end(env)

def _rejects_empty_define_test_impl(ctx):
    # An empty entry becomes a bare `-D`, which the compiler rejects outright —
    # better to name the target than to surface an argument-parsing error.
    env = unittest.begin(ctx)
    err = dart_define_error("", "the `defines` attribute of //pkg:app")
    asserts.true(env, err != None, "an empty define must be rejected")
    asserts.true(env, "//pkg:app" in err, "the message should name the source: %s" % err)
    return unittest.end(env)

def _rejects_empty_key_test_impl(ctx):
    env = unittest.begin(ctx)
    err = dart_define_error("=value", "test")
    asserts.true(env, err != None, "a define with no key must be rejected")
    return unittest.end(env)

_sound_source_test = unittest.make(_sound_when_compiling_source_test_impl)
_sound_empty_test = unittest.make(_sound_when_no_defines_test_impl)
_rejects_test = unittest.make(_rejects_defines_on_kernel_input_test_impl)
_accepts_usable_test = unittest.make(_accepts_usable_defines_test_impl)
_rejects_empty_test = unittest.make(_rejects_empty_define_test_impl)
_rejects_empty_key_test = unittest.make(_rejects_empty_key_test_impl)

def defines_test_suite(name):
    """Declares the `defines_stage_error` unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _sound_source_test,
        _sound_empty_test,
        _rejects_test,
        _accepts_usable_test,
        _rejects_empty_test,
        _rejects_empty_key_test,
    )
