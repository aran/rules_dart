// A stand-in for the `dart:async` of an embedder: the futures and streams the
// analyzer's `dart:core` refers to.
library dart.async;

abstract class Future<T> {}

abstract class FutureOr<T> {}

abstract class Stream<T> {}
