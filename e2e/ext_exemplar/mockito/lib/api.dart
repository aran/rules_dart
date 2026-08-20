// The cross-file interface `test/api_test.dart` mocks via @GenerateMocks. It
// stays a one-method type on purpose — that is the shape the shim's resolver
// has to reach across files, so it is not reshaped to satisfy
// `one_member_abstracts`. See BUILD.bazel for what that costs.

/// The interface the mockito exemplar mocks across files.
// ignore: one_member_abstracts
abstract class Api {
  /// Fetches the value stored under [key].
  Future<String> fetch(String key);
}
