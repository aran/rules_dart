import 'package:injectable/injectable.dart';

// @module: abstract class whose annotated getters become GetIt
// registrations. The pattern is how users register values they can't
// put an annotation on directly (third-party classes, primitives,
// platform channels, …). @Named overrides the lookup identity so
// callers distinguish multiple registrations of the same type.

/// Module registering values that carry no annotation of their own.
@module
abstract class AppModule {
  /// A named singleton timestamp registration.
  @singleton
  @Named('build-time')
  DateTime get startTime => DateTime.utc(2024);
}
