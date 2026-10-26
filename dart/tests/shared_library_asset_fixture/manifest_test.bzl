"""Checks that a target's manifest names one path for ids sharing a library."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _one_path_test_impl(ctx):
    env = analysistest.begin(ctx)
    manifests = [
        action.content
        for action in analysistest.target_actions(env)
        if action.mnemonic == "FileWrite" and
           action.outputs.to_list()[0].basename.endswith(".native_assets.yaml")
    ]
    asserts.equals(env, 1, len(manifests), "expected one native_assets.yaml write")
    paths = {}
    for asset_id in ctx.attr.asset_ids:
        entry = '"%s": [' % asset_id
        start = manifests[0].find(entry)
        asserts.true(env, start >= 0, "%s missing from manifest: %s" % (asset_id, manifests[0]))
        start += len(entry)
        paths[manifests[0][start:manifests[0].find("]", start)]] = True
    asserts.equals(env, 1, len(paths), "ids name different paths: %s" % manifests[0])
    return analysistest.end(env)

one_path_test = analysistest.make(
    _one_path_test_impl,
    attrs = {"asset_ids": attr.string_list()},
)
