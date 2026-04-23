import 'package:injectable/injectable.dart';

// @singleton: registered at `configureInjection()` time and cached
// forever. Two `locator<DatabaseService>()` calls must return the
// identical instance. The mutable `pings` counter lets tests observe
// that singleton state persists across gets.
@singleton
class DatabaseService {
  int pings = 0;
}
