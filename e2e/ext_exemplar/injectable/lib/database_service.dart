import 'package:injectable/injectable.dart';

// @singleton: registered at `configureInjection()` time and cached
// forever. Two `locator<DatabaseService>()` calls must return the
// identical instance. The mutable `pings` counter lets tests observe
// that singleton state persists across gets.

/// An eagerly-registered singleton service.
@singleton
class DatabaseService {
  /// Mutable state proving the singleton persists across gets.
  int pings = 0;
}
