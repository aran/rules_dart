// Every way a dependent's FFI transform reads a dependency's FFI types.
import 'dart:ffi';

import 'package:outline_ffi/ffi.dart';

int fields(Pointer<Point> p, Pointer<Num> n, Pointer<Packed1> k) =>
    p.ref.x + p.ref.bytes[2] + n.ref.i + k.ref.b;

void store(Pointer<Point> p, Pointer<Num> n) {
  p.ref.x = 3;
  p.ref.y = 1.5;
  n.ref.f = 2.5;
}

int sizes() =>
    sizeOf<Point>() +
    sizeOf<Num>() +
    sizeOf<Packed1>() +
    sizeOf<WithLong>() +
    sizeOf<MyLong>();

int abiInt(Pointer<MyLong> p) => p.value + p[1];

int nested(Pointer<WithLong> w) => w.ref.l + w.ref.p.x;

Point byValue(Pointer<Point> p) => p.ref;

int called(Point p) => p.x;

Pointer<NativeFunction<Int32 Function(Point)>> callback() =>
    Pointer.fromFunction<Int32 Function(Point)>(called, 0);

typedef MakePoint = Point Function(Int32);

Point make(Pointer<NativeFunction<MakePoint>> fp) =>
    fp.asFunction<Point Function(int)>()(1);

int native() => twice(21);

Pointer<Handle> handle(Pointer<Void> p) => p.cast<Handle>();

int helpers() => helper();

final class Outer extends Struct {
  external Point p;

  @Array(2)
  external Array<Packed1> ks;

  external Num n;

  @MyLong()
  external int l;
}

int outer(Pointer<Outer> o) => o.ref.p.x + o.ref.ks[1].b + sizeOf<Outer>();
