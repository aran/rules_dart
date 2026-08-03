"""Analysis-time tests for cross-compilation targets.

These resolve a cross toolchain and inspect the compile action, so they run on
any host without downloading an SDK for the target or executing anything. That
matters twice over: the root workspace sets `--nosandbox_default_allow_network`
(see `tools/preset.bazelrc`), and `dart compile` fetches per-pair SDK artifacts
at action time — so a *building* cross test cannot live here. Byte-level proof
that each target really produces its architecture lives in `e2e/cross_compile`.

Because analysis resolves the cross toolchain from whatever host runs the test,
one suite covers `linux-x64_cross_*` on Linux CI, `macos-arm64_cross_*` on
macOS, and `windows-x64_cross_*` on Windows.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_DART_COMPILE = "DartCompile"

def _compile_argv(env):
    """The argv of the target's DartCompile action, or None."""
    for action in analysistest.target_actions(env):
        if action.mnemonic == _DART_COMPILE:
            return action.argv
    return None

def _flag_value(argv, flag):
    """The token following `flag` in argv, or None if the flag is absent."""
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            return argv[i + 1]
    return None

def _cross_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _compile_argv(env)
    if argv == None:
        asserts.true(env, False, "no %s action on the target" % _DART_COMPILE)
        return analysistest.end(env)

    asserts.equals(
        env,
        ctx.attr.expected_target_os,
        _flag_value(argv, "--target-os"),
        "--target-os",
    )
    asserts.equals(
        env,
        ctx.attr.expected_target_arch,
        _flag_value(argv, "--target-arch"),
        "--target-arch",
    )
    return analysistest.end(env)

# `analysistest.make` hands `config_settings` to a skylib-defined rule, which
# resolves plain label strings in *skylib's* repo context. `Label()` resolves
# here instead, and stringifies to a canonical label that is unambiguous
# wherever it lands.
def _platform_label(name):
    return str(Label("//dart/tests/cross_fixture:" + name))

def _make_cross_flags_test(platform_name):
    return analysistest.make(
        _cross_flags_test_impl,
        attrs = {
            "expected_target_os": attr.string(),
            "expected_target_arch": attr.string(),
        },
        config_settings = {
            "//command_line_option:platforms": [_platform_label(platform_name)],
        },
    )

riscv64_flags_test = _make_cross_flags_test("linux_riscv64")

armv7_flags_test = _make_cross_flags_test("linux_arm")

def _native_has_no_target_flags_test_impl(ctx):
    """A native build must get neither flag.

    `dart_compile.bzl` gates them on a non-empty `target_os`, which is empty for
    native toolchains. Passing `--target-os` for the host would be accepted and
    silently change nothing, so nothing else would catch a regression here.
    """
    env = analysistest.begin(ctx)
    argv = _compile_argv(env)
    if argv == None:
        asserts.true(env, False, "no %s action on the target" % _DART_COMPILE)
        return analysistest.end(env)
    asserts.false(env, "--target-os" in argv, "native build passed --target-os")
    asserts.false(env, "--target-arch" in argv, "native build passed --target-arch")
    return analysistest.end(env)

native_has_no_target_flags_test = analysistest.make(
    _native_has_no_target_flags_test_impl,
)

def _abi_manifest_test_impl(ctx):
    """The code-asset ABI string written for a cross target.

    Pins the whole chain — constraint probe in `target_dart_abi` through to the
    emitted `native_assets.yaml` key. The fixture deliberately uses a
    `dynamic_loading_system` asset: a `cc_shared_library`-backed one would make
    Bazel resolve a cc toolchain for riscv64/armv7 during analysis and fail
    before `target_dart_abi` ever ran, testing the wrong thing.
    """
    env = analysistest.begin(ctx)
    manifests = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith(".native_assets.yaml")
    ]
    asserts.equals(env, 1, len(manifests), "expected one native_assets.yaml write")
    content = manifests[0].content
    asserts.true(
        env,
        ('"native-assets": {"%s"' % ctx.attr.expected_abi) in content,
        "ABI %s missing from manifest: %s" % (ctx.attr.expected_abi, content),
    )
    return analysistest.end(env)

def _make_abi_manifest_test(platform_name):
    return analysistest.make(
        _abi_manifest_test_impl,
        attrs = {"expected_abi": attr.string()},
        config_settings = {
            "//command_line_option:platforms": [_platform_label(platform_name)],
        },
    )

riscv64_abi_test = _make_abi_manifest_test("linux_riscv64")

armv7_abi_test = _make_abi_manifest_test("linux_arm")
