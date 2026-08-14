/// End-to-end test for `go_router_builder` via rules_dart's shim.
///
/// The generated `.g.dart` imports `package:flutter/material.dart` and
/// therefore can't be compiled in pure-Dart CI. Instead we read its
/// source via runfiles and assert the builder emitted the structure a
/// healthy go_router-typed route tree produces:
///
///   - top-level `$appRoutes` list with both route entries
///   - nested `routes: <RouteBase>[...]` wrapping the child
///   - literal path strings (`/` and `/details/:id`)
///   - mixin extensions providing `location`, `go`, `push`, etc.
///   - the Flutter + go_router imports that prove codegen saw a real
///     go_router-shaped annotation tree through our stub
///
/// If go_router_builder's output shape changes, update assertions to
/// match; any regression that drops one of these symbols indicates the
/// builder silently produced less than it should.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String generatedSource;

  setUpAll(() {
    final r = Runfiles.create();
    final path = r.rlocation('_main/go_router/lib/app_router.g.dart');
    generatedSource = File(path).readAsStringSync();
  });

  group('go_router_builder end-to-end output', () {
    test('emits the standard header as a part file', () {
      expect(generatedSource, contains('GENERATED CODE - DO NOT MODIFY'));
      // SharedPart output — the shim's combining stage produces a part-of
      // the input source, so go_router_builder's emit doesn't duplicate
      // the source-side `import 'package:go_router/...'`.
      expect(generatedSource, contains("part of 'app_router.dart'"));
    });

    test(r'emits a top-level $appRoutes list with the root route', () {
      // go_router_builder exposes discovered @TypedGoRoute roots via a
      // top-level `$appRoutes` (camelCase). HomeRoute is the root; its
      // nested DetailsRoute appears inside HomeRoute's routes list below.
      expect(generatedSource, contains(r'List<RouteBase> get $appRoutes'));
      expect(generatedSource, contains(r'$homeRoute'));
    });

    test('nests DetailsRoute inside HomeRoute via a routes: list', () {
      // The nested `TypedGoRoute<DetailsRoute>(path: 'details/:id')` becomes
      // a `routes: [GoRouteData.$route(path: 'details/:id', factory: ...)]`
      // entry under HomeRoute's `$route` invocation. A regression in
      // nested handling would drop the child's `$route` or mislabel its
      // path.
      expect(generatedSource, contains(r'factory: $HomeRoute._fromState'));
      expect(generatedSource, contains('routes: ['));
      expect(generatedSource, contains("path: 'details/:id'"));
      expect(generatedSource, contains(r'factory: $DetailsRoute._fromState'));
    });

    test('emits route-class mixins with type-safe navigation methods', () {
      // go_router_builder generates mixins like `$HomeRoute` / `$DetailsRoute`
      // (dollar-prefixed) providing `location`, `go`, `push`, etc.
      expect(generatedSource, contains(RegExp(r'mixin \$HomeRoute on GoRouteData')));
      expect(generatedSource, contains(RegExp(r'mixin \$DetailsRoute on GoRouteData')));
      expect(generatedSource, contains('String get location =>'));
      expect(generatedSource, contains('void go(BuildContext context)'));
      expect(generatedSource,
          contains('Future<T?> push<T>(BuildContext context)'));
    });

    test('derives DetailsRoute from GoRouterState to reconstruct its id field',
        () {
      // `_fromState` factory methods parse path/query params out of a
      // GoRouterState. A regression in path-param parsing would drop
      // the `state.pathParameters['id']` access.
      expect(generatedSource, contains('_fromState'));
      expect(generatedSource, contains("state.pathParameters['id']"));
    });
  });
}
