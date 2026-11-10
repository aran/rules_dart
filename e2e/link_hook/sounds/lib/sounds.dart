/// Sounds an app plays. Which ones ship is decided at link time.
library;

import 'package:meta/meta.dart' show RecordUse;

/// A sound, named the way the package's `assets/` names its file.
///
/// Construct it with `const`: the package's link hook reads each constant's
/// [name] from the compiler's recorded uses and ships only those sounds.
@RecordUse()
final class Sound {
  /// Creates the sound called [name].
  const new(this.name);

  /// The sound's name, its file's without the extension.
  final String name;

  /// The id of the data asset holding the sound.
  String get assetId => 'package:sounds/$name.txt';
}
