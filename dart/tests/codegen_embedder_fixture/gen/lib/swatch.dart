import 'dart:ui';

import 'package:fake_app/middle.dart';

/// A colour, and the one it starts from.
class Swatch {
  /// A swatch of [color].
  Swatch(this.color);

  /// Its colour.
  final Color color;

  /// The colour every swatch starts from.
  static const Color initial = red;
}
