void expectEquals(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw AssertionError('$message: expected $expected, got $actual');
  }
}
