// A stand-in for the `dart:core` of an embedder: only the declarations the
// analyzer needs to type code that imports `dart:ui`.
library dart.core;

import 'dart:async';

class Object {
  const Object();
}

class Null {}

class Type {}

class Function {}

class Symbol {}

class Invocation {}

class Error {}

class Exception {}

class Deprecated {
  const Deprecated(String message);
}

class Override {
  const Override();
}

class pragma {
  const pragma(String name);
}

abstract class num {}

abstract class int extends num {}

abstract class double extends num {}

abstract class bool {}

abstract class String {}

abstract class Iterable<E> {}

abstract class Iterator<E> {}

abstract class List<E> extends Iterable<E> {}

abstract class Set<E> extends Iterable<E> {}

abstract class Map<K, V> {}

class Record {}

typedef AsyncFuture = Future<void>;

void print(Object? object) {}
