// A sibling `lib/` file importing the other by `package:` URI. The
// self-import is not only the entrypoint's problem: a package's own sources
// reach each other this way too, and a closure with no record of the package
// breaks every one of those edges at once.
import 'package:analysis_exec/greeter.dart';

/// Builds a greeting report for [names].
String report(List<String> names) => names.map(greet).join('\n');
