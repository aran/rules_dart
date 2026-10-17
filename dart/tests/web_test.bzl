"""Tests for the hermetic dart_js_binary/dart_wasm_binary implementation.

The web compile must be a direct `dart` invocation over staged declared
artifacts — no shell, no mktemp — with every dep package (including the
empty-lib_root root package) present in the staged package_config.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _find_action(env, mnemonic):
    for action in analysistest.target_actions(env):
        if action.mnemonic == mnemonic:
            return action
    return None

def _web_compile_is_hermetic_test_impl(ctx):
    env = analysistest.begin(ctx)

    compile_action = _find_action(env, "DartCompileWeb")
    asserts.true(env, compile_action != None, "expected a DartCompileWeb action")
    argv = compile_action.argv
    asserts.true(
        env,
        argv[0].endswith("/dart") or argv[0].endswith("\\dart.exe") or argv[0].endswith("/dart.exe"),
        "web compile must invoke the dart binary directly, got: %s" % argv[0],
    )
    asserts.true(env, "compile" in argv, "missing `compile` in argv: %s" % argv)
    asserts.true(env, "js" in argv or "wasm" in argv, "missing mode in argv: %s" % argv)
    asserts.true(env, "-o" in argv, "missing -o in argv: %s" % argv)

    # A define containing a space must survive as ONE argv element.
    asserts.true(
        env,
        "-Dbanner=hello world" in argv,
        "space-containing define must be a single argv element: %s" % argv,
    )

    asserts.true(
        env,
        "--multi-root-scheme=org-dartlang-bazel" in argv or
        "-E--multi-root-scheme=org-dartlang-bazel" in argv,
        "web compile must configure the org-dartlang-bazel multi-root scheme: %s" % argv,
    )
    asserts.true(
        env,
        "--multi-root=." in argv or "-E--multi-root=." in argv,
        "web compile must root org-dartlang-bazel at the exec root: %s" % argv,
    )
    asserts.true(
        env,
        any([a.startswith("--packages=org-dartlang-bazel:///") for a in argv]),
        "web compile must address package_config via org-dartlang-bazel: %s" % argv,
    )
    asserts.true(
        env,
        argv[-1].startswith("org-dartlang-bazel:///"),
        "web compile entrypoint must use org-dartlang-bazel scheme, got: %s" % argv[-1],
    )

    config_content = None
    for action in analysistest.target_actions(env):
        for out in action.outputs.to_list():
            if out.basename == "package_config.json":
                config_content = action.content
    asserts.true(env, config_content != None, "expected a staged package_config.json write")
    asserts.true(
        env,
        '"name": "pc_own_srcs_fixture"' in config_content,
        "dep package missing from staged package_config: %s" % config_content,
    )
    return analysistest.end(env)

web_compile_hermetic_test = analysistest.make(_web_compile_is_hermetic_test_impl)
