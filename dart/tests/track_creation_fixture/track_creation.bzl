"""Builds an executable with `track_creation_locations` on or off, and runs it."""

load("//dart:defs.bzl", "dart_test")

_FLAG = str(Label("//dart:track_creation_locations"))

def _transition_impl(_settings, attr):
    return {_FLAG: attr.track}

_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = [_FLAG],
)

def _built_impl(ctx):
    actual = ctx.attr.actual[0]
    return [
        DefaultInfo(
            files = depset([actual[DefaultInfo].files_to_run.executable]),
            runfiles = actual[DefaultInfo].default_runfiles,
        ),
    ]

_built = rule(
    implementation = _built_impl,
    attrs = {
        "actual": attr.label(cfg = _transition, executable = True, mandatory = True),
        "track": attr.bool(mandatory = True),
    },
)

def track_creation_locations_run_test(name, actual, track, **kwargs):
    """A test that passes when `actual`, built with the flag as given, exits 0.

    Args:
      name: Test name.
      actual: A `dart_test` or `dart_binary` target.
      track: The value of `//dart:track_creation_locations` to build it with.
      **kwargs: Passed to the test.
    """
    built = name + "_built"
    _built(
        name = built,
        actual = actual,
        track = track,
        tags = ["manual"],
        testonly = True,
    )
    dart_test(
        name = name,
        data = [built],
        env = {"ACTUAL": "$(rlocationpath :%s)" % built},
        main = "driver.dart",
        deps = ["//dart/runfiles"],
        **kwargs
    )
