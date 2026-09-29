"""The `dart_analyze` aspect: `dart analyze` and `dart format` for every Dart target a test run names.

Enable it in `.bazelrc`, with one `--output_groups` line per check you want:

    test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
    test --output_groups=+dart_analyze
    test --output_groups=+dart_format
    common --@rules_dart//dart:analysis_config=//:analysis_config

`//:analysis_config` is a `dart_analysis_config` listing every
`dart_analysis_options` in the repository. Each target named on the command line
has its own hand-written files checked under the nearest listed
`analysis_options.yaml`: `dart_analyze` runs the analyzer, and any finding fails
the build; `dart_format` runs `dart format --set-exit-if-changed` with that
file's `formatter:` settings, at the language version of the target's own
package. The flag goes under `common` so `dart_fix` and `dart_format` see the
same options under `bazel run`.

Tag a target `no-dart-analyze` to skip its analysis, `no-dart-format` to skip
its format check. To check a target `bazel test //...` cannot reach (tagged
`manual`), list it in a `dart_analysis_test`.
"""

load("//dart/private:dart_analyze_aspect.bzl", _dart_analyze = "dart_analyze")

dart_analyze = _dart_analyze
