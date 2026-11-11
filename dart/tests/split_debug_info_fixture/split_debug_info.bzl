"""Builds a `dart_binary` with `split_debug_info` on or off, with what it writes."""

load("//dart:defs.bzl", "dart_test")

_FLAG = str(Label("//dart:split_debug_info"))

def _transition_impl(_settings, attr):
    return {_FLAG: attr.split}

_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = [_FLAG],
)

def _built_impl(ctx):
    actual = ctx.attr.actual[0]
    symbols = actual[OutputGroupInfo].debug_info.to_list()
    return [
        DefaultInfo(
            files = depset([actual[DefaultInfo].files_to_run.executable] + symbols),
            runfiles = actual[DefaultInfo].default_runfiles.merge(ctx.runfiles(symbols)),
        ),
    ]

_built = rule(
    implementation = _built_impl,
    attrs = {
        "actual": attr.label(cfg = _transition, executable = True, mandatory = True),
        "split": attr.bool(mandatory = True),
    },
)

def split_debug_info_run_test(name, actual, split, **kwargs):
    """A test that runs `actual`, built with the flag as given, and checks its trace.

    Args:
      name: Test name.
      actual: A `dart_binary` target.
      split: The value of `//dart:split_debug_info` to build it with.
      **kwargs: Passed to the test.
    """
    built = name + "_built"
    _built(
        name = built,
        actual = actual,
        split = split,
        tags = ["manual"],
        testonly = True,
    )
    dart_test(
        name = name,
        data = [built],
        env = {
            "BUILT": "$(rlocationpaths :%s)" % built,
            "SPLIT": str(split).lower(),
        },
        main = "driver.dart",
        deps = ["//dart/runfiles"],
        **kwargs
    )
