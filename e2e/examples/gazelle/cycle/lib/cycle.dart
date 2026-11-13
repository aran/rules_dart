// lib/, lib/src/a and lib/src/b import each other in a chain, and lib/src/c
// and lib/src/d import each other: import cycles inside a package are
// ordinary Dart, and the package's one library, at its root, holds them all.
export 'src/a/a.dart';
export 'src/c/c.dart';

/// The greeting every part of the package shares.
const greeting = 'hello';
