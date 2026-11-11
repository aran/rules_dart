/// Native operations a program picks. Which libraries ship is decided at
/// link time.
library;

import 'package:meta/meta.dart' show RecordUse;

/// An operation, named as its native library is.
///
/// Construct it with `const`: the package's link hook reads each constant's
/// [name] from the compiler's recorded uses and keeps only those libraries.
@RecordUse()
final class Op {
  /// Creates the operation called [name].
  const new(this.name);

  /// The operation's name, its code asset's within the package.
  final String name;
}
