/// Faults a program asks its link hook to commit.
library;

import 'package:meta/meta.dart' show RecordUse;

/// One fault, named by [kind]; the package's link hook commits it.
@RecordUse()
final class Fault {
  /// Creates the fault called [kind].
  const new(this.kind);

  /// What the hook does wrong.
  final String kind;
}
