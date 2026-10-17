// A pre-3.0 library whose plain `class` has no `mixin` or `mixin class`
// modifier, yet is legal in a `with` clause in Dart 3 consumers.
class LegacyMixin {
  final String tag = 'legacy';
  int count = 10;

  String get label => '$tag:$count';

  set bump(int delta) {
    count += delta;
  }

  String greet(String who) => 'hello $who ($label)';
}
