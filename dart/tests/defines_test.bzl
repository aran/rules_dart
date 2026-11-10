"""Tests that `defines` and front-end flags reach the action which runs the front end.

`-D` values are resolved during constant evaluation, so they take effect only
in the action that compiles source. `dart_binary` compiles in two steps —
`frontend_server` produces the kernel, then `dart compile` turns it into an
executable — and `dart compile` accepts `-D` on a kernel input while silently
ignoring it. Nothing fails, the define just evaporates, so these tests pin
which step receives the flag, with and without code assets.

A define value with a comma reaches the program whole through `frontend_server`.
`dart_test` compiles its modules with `kernel_worker`, which splits it, so a
test refuses one.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:build_settings.bzl", "dart_define_error")
load("//dart/private:dart_compile.bzl", "front_end_flags")
load(":small_suite.bzl", "small_unittest_suite")

_KERNEL = "DartKernel"
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
    # The front end runs in the kernel step, so that is where the define has
    # to land. Passing it again to the kernel->exe step would be a silent
    # no-op, which is exactly how the original bug read as "supported".
    env = analysistest.begin(ctx)
    kernel = _argv_for(env, _KERNEL)
    dart_compile = _argv_for(env, _DART_COMPILE)
    if kernel == None or dart_compile == None:
        asserts.true(
            env,
            False,
            "expected both a %s and a %s action, saw %s" %
            (_KERNEL, _DART_COMPILE, _mnemonics(env)),
        )
        return analysistest.end(env)
    for flag in ctx.attr.expected_flags:
        asserts.true(
            env,
            flag in kernel,
            "%s missing from the front-end step: %s" % (flag, kernel),
        )
        asserts.true(
            env,
            flag not in dart_compile,
            "%s must not be repeated on the kernel->exe step: %s" % (flag, dart_compile),
        )
    return analysistest.end(env)

staged_defines_test = analysistest.make(
    _staged_defines_test_impl,
    attrs = {"expected_flags": attr.string_list()},
)

def _frontend_argv(argv):
    """The front end's own command line, snapshot first, or None if not as expected.

    It follows the `--` of `kernel_tool frontend`.
    """
    if "--" not in argv or "kernel_tool" not in argv[0] or argv[1:2] != ["frontend"]:
        return None
    return argv[argv.index("--") + 1:]

def _kernel_command_test_impl(ctx):
    # The front end the kernel step runs, and how: `frontend_server` reading
    # the sources through the exec-root filesystem and writing `--output-dill`,
    # with each define one argument, a comma in it included, run through
    # `kernel_tool frontend`, which keeps the server's protocol out of the
    # build log.
    env = analysistest.begin(ctx)
    full = _argv_for(env, _KERNEL)
    if full == None:
        asserts.true(env, False, "expected a %s action, saw %s" % (_KERNEL, _mnemonics(env)))
        return analysistest.end(env)
    argv = _frontend_argv(full)
    if argv == None:
        asserts.true(env, False, "the kernel step runs through kernel_tool, saw %s" % full)
        return analysistest.end(env)
    asserts.true(
        env,
        argv[0].endswith("/frontend_server_aot.dart.snapshot"),
        "the kernel step must run frontend_server: %s" % argv,
    )
    asserts.equals(env, [], [a for a in argv if "gen_kernel" in a], "gen_kernel in %s" % argv)
    for flag, value in [
        ("--filesystem-scheme", "org-dartlang-root"),
        ("--filesystem-root", "."),
        ("--platform", "vm_platform_product.dill"),
    ]:
        values = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]
        asserts.true(env, value in values, "%s %s missing: %s" % (flag, value, argv))

    # `frontend_server` reads `--platform` relative to `--sdk-root`, and a
    # platform that does not resolve there is not reported as missing: the
    # compile crashes later, in type inference. So the two must name an input.
    action = [a for a in analysistest.target_actions(env) if a.mnemonic == _KERNEL][0]
    input_paths = [f.path for f in action.inputs.to_list()]
    sdk_roots = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--sdk-root"]
    platforms = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--platform"]
    asserts.equals(env, 1, len(sdk_roots), "one --sdk-root: %s" % argv)
    asserts.equals(env, 1, len(platforms), "one --platform: %s" % argv)
    if len(sdk_roots) == 1 and len(platforms) == 1:
        asserts.true(
            env,
            sdk_roots[0].endswith("/") and (sdk_roots[0] + platforms[0]) in input_paths,
            "--sdk-root %s and --platform %s must resolve to a platform dill the action reads; its inputs are %s" % (sdk_roots[0], platforms[0], input_paths),
        )

    # The front end's runtime is an input.
    runtimes = [p for p in input_paths if p.endswith("/dartaotruntime") or p.endswith("/dartaotruntime.exe")]
    asserts.equals(env, 1, len(runtimes), "the runtime must be an input: %s" % input_paths)
    given = [full[i + 1] for i in range(len(full) - 1) if full[i] == "--runtime"]
    asserts.equals(env, runtimes, given, "--runtime must name the input: %s" % full)
    asserts.true(env, "--output-dill" in argv and "-o" not in argv, "the output goes to --output-dill: %s" % argv)
    asserts.true(env, "--no-print-incremental-dependencies" in argv, "the files read would be named in the log: %s" % argv)
    asserts.true(env, "-Ddart.vm.product=true" in argv, "product mode missing: %s" % argv)
    for flag in ctx.attr.expected_flags:
        asserts.true(env, flag in argv, "%s missing, or split: %s" % (flag, argv))
    return analysistest.end(env)

kernel_command_test = analysistest.make(
    _kernel_command_test_impl,
    attrs = {
        "expected_flags": attr.string_list(),
    },
)

def _bootstrap_kernel_command_test_impl(ctx):
    # `kernel_tool` and the tools built beside it cannot run through it, and
    # `frontend_server` run directly prints its protocol on success, so they
    # are compiled by `gen_kernel`, which prints only diagnostics, reading the
    # sources through the same exec-root filesystem.
    env = analysistest.begin(ctx)
    full = _argv_for(env, _KERNEL)
    if full == None:
        asserts.true(env, False, "expected a %s action, saw %s" % (_KERNEL, _mnemonics(env)))
        return analysistest.end(env)
    asserts.true(env, "dartaotruntime" in full[0], "the runtime runs the compiler: %s" % full)
    asserts.true(env, full[1].endswith("/gen_kernel_aot.dart.snapshot"), "the compiler is gen_kernel: %s" % full)
    asserts.equals(env, [], [a for a in full if "frontend_server" in a], "frontend_server in %s" % full)
    action = [a for a in analysistest.target_actions(env) if a.mnemonic == _KERNEL][0]
    input_paths = [f.path for f in action.inputs.to_list()]
    for flag, value in [
        ("--filesystem-scheme", "org-dartlang-root"),
        ("--filesystem-root", "."),
    ]:
        values = [full[i + 1] for i in range(len(full) - 1) if full[i] == flag]
        asserts.true(env, value in values, "%s %s missing: %s" % (flag, value, full))
    platforms = [full[i + 1] for i in range(len(full) - 1) if full[i] == "--platform"]
    asserts.true(
        env,
        len(platforms) == 1 and platforms[0].endswith("/vm_platform_product.dill") and platforms[0] in input_paths,
        "one --platform naming the product platform the action reads: %s" % full,
    )
    asserts.true(env, "--output" in full and "--output-dill" not in full, "the output goes to --output: %s" % full)
    asserts.true(env, "-Ddart.vm.product=true" in full, "product mode missing: %s" % full)
    return analysistest.end(env)

bootstrap_kernel_command_test = analysistest.make(_bootstrap_kernel_command_test_impl)

def _comma_refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "a define of a program compiled in modules cannot have a comma in its value")
    return analysistest.end(env)

comma_refused_test = analysistest.make(_comma_refused_test_impl, expect_failure = True)

comma_refused_whole_program_test = analysistest.make(
    _comma_refused_test_impl,
    expect_failure = True,
    config_settings = {str(Label("//dart:modular_kernel")): False},
)

# --- front_end_flags ---

def _splits_front_end_flags_test_impl(ctx):
    env = unittest.begin(ctx)
    front_end, rest = front_end_flags([
        "--enable-experiment=x",
        "--extra-gen-snapshot-options=--optimization_level=3",
        "-DA=1",
        "--define=B=2",
        "--verbosity=all",
    ])
    asserts.equals(env, ["--enable-experiment=x", "-DA=1", "--define=B=2", "--verbosity=all"], front_end)
    asserts.equals(env, ["--extra-gen-snapshot-options=--optimization_level=3", "--verbosity=all"], rest)
    return unittest.end(env)

def _splits_separate_values_test_impl(ctx):
    # A value given as the next element goes with its flag.
    env = unittest.begin(ctx)
    front_end, rest = front_end_flags([
        "-D",
        "A=1",
        "--verbosity",
        "error",
        "--define",
        "B=2",
        "--enable-experiment",
        "x",
    ])
    asserts.equals(env, ["-D", "A=1", "--verbosity", "error", "--define", "B=2", "--enable-experiment", "x"], front_end)
    asserts.equals(env, ["--verbosity", "error"], rest)
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

_splits_test = unittest.make(_splits_front_end_flags_test_impl)
_splits_separate_values_test = unittest.make(_splits_separate_values_test_impl)
_accepts_usable_test = unittest.make(_accepts_usable_defines_test_impl)
_rejects_empty_test = unittest.make(_rejects_empty_define_test_impl)
_rejects_empty_key_test = unittest.make(_rejects_empty_key_test_impl)

def defines_test_suite(name):
    """Declares the `front_end_flags` and `dart_define_error` unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _splits_test,
        _splits_separate_values_test,
        _accepts_usable_test,
        _rejects_empty_test,
        _rejects_empty_key_test,
    )
