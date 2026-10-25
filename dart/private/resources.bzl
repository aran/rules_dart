"""What the Dart SDK's heavier actions use, for Bazel's local scheduler.

Bazel assumes an action takes one core and 250 MB. The SDK's tools run in one
Dart VM and use about one core, but the front end, the analysis server and
`gen_snapshot` hold a whole program in memory. Measured peaks, on rules_dart's
own targets (the `dart/ext` builder shims, which import the analyzer and
`package:build`): kernel 455–546 MB, analysis 549–640 MB, native compile
688–828 MB. Each declares its upper figure rounded up, so the scheduler stops
before the machine swaps rather than after.
"""

def analysis_resources(_os, _inputs):
    return {"cpu": 1, "memory": 700}

def kernel_resources(_os, _inputs):
    return {"cpu": 1, "memory": 600}

def native_compile_resources(_os, _inputs):
    return {"cpu": 1, "memory": 900}
