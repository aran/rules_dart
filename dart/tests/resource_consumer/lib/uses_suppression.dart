/// Carries the diagnostic the included options file suppresses.
///
/// `unused_local_variable` is an info, and `dart_analyze_test` runs with
/// `--fatal-infos`, so this file analyzes clean only while
/// `package:resource_fixture/strict.yaml` is reachable from the staged project.
library;

void unusedLocal() {
  var suppressed = 1;
}
