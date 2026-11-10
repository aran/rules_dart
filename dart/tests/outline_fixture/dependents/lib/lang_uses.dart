// Every way a dependent copies or evaluates a dependency's code.
import 'package:outline_lang/lang.dart';
import 'package:outline_plain/plain.dart';

class Mine extends Base with Greets {
  Mine() : super(1);
}

class MineLegacy with LegacyMixin {}

class MineCounter with Counter {}

class Loud extends Silent {}

class Wide extends Base {
  Wide() : super.named();

  @override
  int twice([int f = 3]) => super.twice(f);
}

class Next extends Plain {
  Next() : super(1);
}

const p = Pt<String>(1, 2, 'x');
const origin = Pt<int>.origin();
const evaluated = [p, origin, Color.green, topConst, Base.sc, IntX.unit];
const environment = fromEnvironment ? 1 : 2;
const meters = Meters(1.5);
const zero = Meters.zero();

@tagged
@Tag('dependent')
String area(Shape s) => switch (s) {
  Sq(s: final x) => 'sq $x',
  Ci(r: final r) => 'ci $r',
};

String col(Color c) => switch (c) {
  Color.red => c.describe(),
  Color.green => c.code,
};

Object run() {
  final m = Mine()..greet('a');
  final l = MineLegacy().legacyMethod();
  final mc = MineCounter()..bump();
  final cmp = Composite(3)..bump(4);
  final b = Base.redirect(4).twice();
  final Pair pair = (1, name: 'n');
  return [
    m,
    l,
    mc.count,
    cmp.count,
    cmp.greet('z', greeting: 'yo'),
    b,
    3.doubled,
    (meters + zero).km,
    pair,
    evaluated,
    environment,
    area(Sq(1)),
    col(Color.red),
    Color.red.label,
    identity(Color.green.index),
    topFinal,
    lateTop,
    Legacyish().legacyMethod(),
    helper2(),
    Base.named().id,
    Loud().talk(2),
    Wide().twice(),
    Next().next(),
    plainHelper(),
  ];
}
