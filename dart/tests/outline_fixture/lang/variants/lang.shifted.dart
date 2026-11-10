// Language features whose code dependents copy or evaluate: mixins, constant
// constructors and fields, enums, redirecting factories, extension types.
import 'legacy.dart';

export 'legacy.dart';

const int topConst = 6 * 7;
const bool fromEnvironment = bool.fromEnvironment('outline.fixture');
final int topFinal = DateTime.now().millisecond;
late int lateTop = 3;

class Tag {
  final String name;
  const Tag(this.name);
}

const tagged = Tag('tagged');

mixin Greets on Object {
  int greetCount = 1;
  String greet(String who, {String greeting = 'hi'}) =>
      '$greeting $who ${greetCount++}';
}

mixin Labelled {
  String get label => 'label $hashCode';
}

mixin class Counter {
  int count = 0;
  void bump([int by = 2]) => count += by;
}

class Base {
  final int id;
  Base(this.id) {
    print('base constructor body');
  }
  Base.named() : id = -1;
  factory Base.redirect(int id) = Base;
  int twice([int f = 2]) => id * f;
  static const sc = 'static const';
}

class Composite extends Base with Greets, Counter {
  Composite(super.id);
}

class Legacyish extends Object with LegacyMixin {}

enum Color with Labelled {
  red('r'),
  green('g');

  final String code;
  const Color(this.code);
  String describe() => 'color $code';
}

class Pt<T> {
  final int x;
  final int y;
  final int sum;
  final T? extra;
  const Pt(this.x, this.y, [this.extra]) : sum = x + y;
  const factory Pt.origin() = Pt<T>.zero;
  const Pt.zero() : this(0, 0);
  final List<int> constList = const [1];
}

sealed class Shape {}

final class Sq extends Shape {
  final double s;
  Sq(this.s);
}

final class Ci extends Shape {
  final double r;
  Ci(this.r);
}

extension IntX on int {
  static const unit = 1;
  int get doubled => this * 2;
}

extension type const Meters(double value) {
  const Meters.zero() : this(0);
  Meters operator +(Meters o) => Meters(value + o.value);
  double get km => value / 1000;
}

abstract class Talker {
  String talk(int times, {String word = 'hello'});
}

class Silent implements Talker {
  @override
  dynamic noSuchMethod(Invocation invocation) => 'silence';
}

typedef Pair = (int, {String name});

T identity<T>(T t) => t;

@tagged
int helper2() {
  return 40 + 1;
}
