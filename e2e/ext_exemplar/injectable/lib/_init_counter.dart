// Top-level counter used by api_client.dart to prove @lazySingleton
// defers construction until the first `GetIt.get<ApiClient>()` call.
// Tests reset and read this counter to observe lazy-init timing.
int apiClientInitCount = 0;
