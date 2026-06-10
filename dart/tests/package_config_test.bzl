"""Tests that binary/test package_config generation sees the rule's own srcs.

A package whose metadata arrives via a `dart_library` façade (srcs = []) but
whose files arrive through the consuming rule's own `srcs` must still get a
`package_config.json` entry — root resolution has to scan dep sources AND the
rule's own inputs. Regression: only `dep_srcs` were scanned, so the façade
package was silently dropped and its `package:` imports failed to resolve.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _package_config_content(env):
    for action in analysistest.target_actions(env):
        for out in action.outputs.to_list():
            if out.basename.endswith(".package_config.json"):
                return action.content
    return None

def _includes_own_srcs_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    content = _package_config_content(env)
    asserts.true(env, content != None, "expected a package_config.json write action")
    asserts.true(
        env,
        '"name": "pc_own_srcs_fixture"' in content,
        "own-srcs package missing from package_config: %s" % content,
    )
    return analysistest.end(env)

package_config_own_srcs_test = analysistest.make(_includes_own_srcs_package_test_impl)
