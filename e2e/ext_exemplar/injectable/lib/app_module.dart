import 'package:injectable/injectable.dart';

// @module: abstract class whose annotated getters become GetIt
// registrations. The pattern is how users register values they can't
// put an annotation on directly (third-party classes, primitives,
// platform channels, …). @Named overrides the lookup identity so
// callers distinguish multiple registrations of the same type.
@module
abstract class AppModule {
  @singleton
  @Named('build-time')
  DateTime get startTime => DateTime.utc(2024);
}
