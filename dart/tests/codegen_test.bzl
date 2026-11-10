"""Tests for the codegen rules: output names, action inputs and language version."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:dart_codegen.bzl", "compute_codegen_output_name")
load(":small_suite.bzl", "small_unittest_suite")

def _g_dart_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("user.dart", ".g.dart")
    asserts.equals(env, "user.g.dart", result)
    return unittest.end(env)

def _freezed_suffix_with_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("some/dir/model.dart", ".freezed.dart")
    asserts.equals(env, "some/dir/model.freezed.dart", result)
    return unittest.end(env)

def _custom_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    result = compute_codegen_output_name("router.dart", ".gr.dart")
    asserts.equals(env, "router.gr.dart", result)
    return unittest.end(env)

_t0_test = unittest.make(_g_dart_suffix_test_impl)
_t1_test = unittest.make(_freezed_suffix_with_dir_test_impl)
_t2_test = unittest.make(_custom_suffix_test_impl)

def codegen_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test)

# --- inputs of the codegen actions ---

def _codegen_inputs_test_impl(ctx):
    # A generator sees the package its target declares: every file of every
    # dependency, resources included. The action is the only thing that stages
    # them, so a file missing from its inputs is absent in a sandbox or on a
    # remote executor (and present, undeclared, in a worker or a local run).
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic in ["DartCodegen", "DartAggregateCodegen", "DartSqlCodegen"]]
    asserts.true(env, actions, "no codegen action")
    for action in actions:
        paths = [f.path for f in action.inputs.to_list()]
        asserts.true(
            env,
            [p for p in paths if p.endswith("dep/lib/dep.dart")] != [],
            "dependency source missing from inputs: %s" % paths,
        )
        asserts.true(
            env,
            [p for p in paths if p.endswith("dep/lib/template.txt")] != [],
            "dependency resource `lib/template.txt` is not an input of the codegen action",
        )
    return analysistest.end(env)

codegen_inputs_test = analysistest.make(_codegen_inputs_test_impl)

# --- the language version of a target that states none ---

def _codegen_language_version_test_impl(ctx):
    # A codegen target whose package states no `language_version` runs its generator at the
    # SDK's own, which is what the package compiles at and what the analyzer
    # and the format check assume for it (`default_language_version`): never a
    # value of its own.
    env = analysistest.begin(ctx)
    major, minor = ctx.attr._toolchain[platform_common.ToolchainInfo].dart_sdk_info.version.split(".")[:2]
    expected = "%s.%s" % (major, minor)
    actions = analysistest.target_actions(env)
    runs = [a for a in actions if a.mnemonic in ["DartCodegen", "DartAggregateCodegen", "DartSqlCodegen"]]
    asserts.true(env, runs, "no codegen action")
    for action in runs:
        argv = action.argv
        asserts.true(env, "--root-language-version" in argv, "no --root-language-version in %s" % argv)
        asserts.equals(env, expected, argv[argv.index("--root-language-version") + 1])
    pubspecs = [a for a in actions if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename == "pubspec.yaml"]
    asserts.equals(env, 1, len(pubspecs), "one written pubspec")
    asserts.true(
        env,
        'sdk: "^%s.0"' % expected in pubspecs[0].content,
        "pubspec states another SDK: %s" % pubspecs[0].content,
    )
    return analysistest.end(env)

codegen_language_version_test = analysistest.make(
    _codegen_language_version_test_impl,
    attrs = {"_toolchain": attr.label(default = "//dart:resolved_toolchain")},
)
