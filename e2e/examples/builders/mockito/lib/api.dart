// The cross-file interface `test/api_test.dart` mocks via @GenerateMocks. It
// stays a one-method type on purpose — that is the shape the shim's resolver
// has to reach across files.

/// The interface the mockito exemplar mocks across files.
abstract class Api {
  /// Fetches the value stored under [key].
  Future<String> fetch(String key);
}
