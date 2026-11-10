"""Unit tests for dart_codegen.bzl output filename computation."""

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
