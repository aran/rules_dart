/// Native operations, of which a program's library keeps those it uses.
library;

import 'package:meta/meta.dart' show RecordUse;

/// An operation, named as its native symbol is after `trim_`.
///
/// Construct it with `const`: the package's `symbols` tool reads each
/// constant's [name] from the compiler's recorded uses.
@RecordUse()
final class TrimOp {
  /// Creates the operation called [name].
  const new(this.name);

  /// The operation's name.
  final String name;
}
