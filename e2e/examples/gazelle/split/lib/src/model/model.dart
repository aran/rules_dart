import '../util/util.dart';

/// A named thing.
class Model {
  /// Creates a model called [name].
  Model(this.name);

  /// The model's name.
  final String name;

  @override
  String toString() => 'model ${trimmed(name)}';
}
