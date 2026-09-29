"""The `dart_analyze` aspect: `dart analyze` for every Dart target a test run names.

Enable it in `.bazelrc`:

    test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
    test --output_groups=+dart_analyze
    common --@rules_dart//dart:analysis_config=//:analysis_config

`//:analysis_config` is a `dart_analysis_config` listing every
`dart_analysis_options` in the repository. Each target named on the command line
has its own hand-written files analyzed, under the nearest listed
`analysis_options.yaml`, and any finding fails the build. The flag goes under
`common` so `dart_fix` sees the same options under `bazel run`.

Tag a target `no-dart-analyze` to skip it.
"""

load("//dart/private:dart_analyze_aspect.bzl", _dart_analyze = "dart_analyze")

dart_analyze = _dart_analyze
