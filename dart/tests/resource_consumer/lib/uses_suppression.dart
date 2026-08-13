/// Carries the diagnostic the included options file suppresses.
///
/// `unused_local_variable` is an info, and `dart_analyze_test` runs with
/// `--fatal-infos`, so this file analyzes clean only while
/// `package:resource_fixture/strict.yaml` is reachable from the staged project.
library;

import 'package:resource_fixture/marker.dart';

void unusedLocal() {
  var suppressed = 1;
}

/// Imports a dependency by `package:` URI so `depend_on_referenced_packages`
/// has something to judge. Under Bazel a dep arrives through the staged
/// `package_config.json`, never through a pubspec, so this analyzes clean only
/// while the synthesized pubspec stub lists the packages that config carries.
String markerName() => marker;
