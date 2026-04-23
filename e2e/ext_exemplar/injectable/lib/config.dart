import 'package:injectable/injectable.dart';

// @Environment filters: registrations only apply when
// `configureInjection(environment: '...')` matches the annotation. With
// two env-gated implementations of the same abstract class, switching
// the configured env swaps which concrete class GetIt resolves.
abstract class AppConfig {
  String get label;
}

// `@Injectable(as: AppConfig)` registers each concrete class under the
// AppConfig interface type so `GetIt.get<AppConfig>()` resolves the
// environment-matching implementation. Without `as:`, the class would
// only be retrievable by its concrete type.
@Environment('dev')
@Injectable(as: AppConfig)
class DevConfig implements AppConfig {
  @override
  String get label => 'dev-config';
}

@Environment('prod')
@Injectable(as: AppConfig)
class ProdConfig implements AppConfig {
  @override
  String get label => 'prod-config';
}
