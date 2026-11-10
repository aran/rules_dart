# dart_test_on

A test file's `@TestOn` becomes its `dart_test`'s `target_compatible_with`,
so that Bazel skips the test on a platform package:test would not run it on.
The selector is evaluated over the Dart VM on each OS and rules_dart's web
platforms, which carry a `runtime` value and no OS, as a browser has none
for package:test. A `target_compatible_with` the file's `@TestOn` no longer
gives leaves the target; one marked `# keep` stays.
