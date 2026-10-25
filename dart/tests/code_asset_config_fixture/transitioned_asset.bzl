"""A code asset built in another configuration than the test that loads it."""

load("//dart:providers.bzl", "DartCodeAssetInfo")

def _transitioned_impl(_settings, _attr):
    return {str(Label(":transitioned")): True}

_transitioned = transition(
    implementation = _transitioned_impl,
    inputs = [],
    outputs = [str(Label(":transitioned"))],
)

def _transitioned_asset_impl(ctx):
    asset = ctx.attr.asset[0]
    return [asset[DefaultInfo], asset[DartCodeAssetInfo]]

transitioned_asset = rule(
    implementation = _transitioned_asset_impl,
    attrs = {
        "asset": attr.label(cfg = _transitioned, providers = [DartCodeAssetInfo]),
    },
    provides = [DartCodeAssetInfo],
)
