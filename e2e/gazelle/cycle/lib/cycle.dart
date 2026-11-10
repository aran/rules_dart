// lib/, lib/src/a and lib/src/b import each other in a chain, so Gazelle
// writes one library for the three, here; lib/src/c and lib/src/d import
// each other, so they are one library in lib/src/c.
export 'src/a/a.dart';
export 'src/c/c.dart';

/// The greeting every part of the package shares.
const greeting = 'hello';
