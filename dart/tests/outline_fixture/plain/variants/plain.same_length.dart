// A library with no mixins: its outline keeps no source positions.
class Plain {
  final int n;
  Plain(this.n);
  int next() => n + 1;
}

int plainHelper() => 42;
