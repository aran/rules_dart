"""What the Dart SDK's heavier actions use, for Bazel's local scheduler.

Bazel assumes an action takes one core and 250 MB. The SDK's tools run in one
Dart VM and use about one core, but the front end, the analysis server and
`gen_snapshot` hold a whole program in memory. Measured peaks, on rules_dart's
own targets (the `dart/ext` builder shims, which import the analyzer and
`package:build`): kernel 455–546 MB, analysis 549–640 MB, native compile
688–828 MB. Each declares its upper figure rounded up, so the scheduler stops
before the machine swaps rather than after.

Analysis of a program's whole source, rather than of a target's own files
against its dependencies' summaries, peaks with the size of the program, so its
estimate is chosen when the aspect runs, from the number of `.dart` files the
program can see (`source_analysis_resources`). Bazel hands `resource_set` only
the action's input count, which counts the staged project tree as one file, and
the callback must be a top-level function, so the sizes are a few fixed tiers.
Cold peaks of `dart analyze` on a Flutter app's targets (macOS; a Linux CI
runner about 1.25 times higher): 455 MB at 3,177 files, 921 MB at 3,543 (the
first that imports Flutter), 954 MB, near 1.2 GB on Linux, at 4,544; `dart fix`
peaks within 10% of it. The top tier is past what was measured; it keeps a
larger program from taking a smaller one's share.
"""

visibility("//dart/...")

def analysis_resources(_os, _inputs):
    return {"cpu": 1, "memory": 700}

def _source_analysis_1600(_os, _inputs):
    return {"cpu": 1, "memory": 1600}

def _source_analysis_2400(_os, _inputs):
    return {"cpu": 1, "memory": 2400}

def source_analysis_resources(dart_files):
    """Picks the `resource_set` for analyzing a program's whole source.

    Args:
      dart_files: How many `.dart` files the program can see, the SDK's aside.

    Returns:
      A top-level `resource_set` callback.
    """
    if dart_files < 2500:
        return analysis_resources
    if dart_files < 6000:
        return _source_analysis_1600
    return _source_analysis_2400

def kernel_resources(_os, _inputs):
    return {"cpu": 1, "memory": 600}

def native_compile_resources(_os, _inputs):
    return {"cpu": 1, "memory": 900}
