import 'package:injectable/injectable.dart';

import '_init_counter.dart';

// @lazySingleton: construction is deferred until the first
// `GetIt.get<ApiClient>()`. The top-level counter observes when the
// constructor runs relative to `configureInjection()`, so tests can
// assert the "lazy" in lazySingleton actually defers work.
@lazySingleton
class ApiClient {
  ApiClient() {
    apiClientInitCount += 1;
  }
}
