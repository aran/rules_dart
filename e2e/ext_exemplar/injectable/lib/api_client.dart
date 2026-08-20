import 'package:injectable/injectable.dart';
import 'package:injectable_fixture/_init_counter.dart';

// @lazySingleton: construction is deferred until the first
// `GetIt.get<ApiClient>()`. The top-level counter observes when the
// constructor runs relative to `configureInjection()`, so tests can
// assert the "lazy" in lazySingleton actually defers work.

/// A lazily-constructed singleton service.
@lazySingleton
class ApiClient {
  /// Constructs the client, bumping [apiClientInitCount].
  ApiClient() {
    apiClientInitCount += 1;
  }
}
