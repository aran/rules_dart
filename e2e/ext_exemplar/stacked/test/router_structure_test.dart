/// Structural test for `shim_router` — reads the generated
/// `app.router.dart` via runfiles and asserts it contains the symbols
/// a populated `@StackedApp(routes: [...])` must produce.
///
/// Tracks the stacked_generator 2.0 router-v2 output shape. If the
/// generator drops a route, mistypes path literals, or regresses the
/// `$appRoutes`/`RouteDef` scaffolding, one of these assertions fires.

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String generated;

  setUpAll(() {
    final r = Runfiles.create();
    generated =
        File(r.rlocation('_main/stacked/lib/app.router.dart')).readAsStringSync();
  });

  test('emits the stacked router generator header + Flutter imports', () {
    expect(generated, contains('GENERATED CODE - DO NOT MODIFY'));
    // stacked_generator 2.0.2 emits `StackedNavigatorGenerator` (older
    // versions used `StackedRouterGenerator`). Accept either so this
    // test is robust across minor upgrades.
    expect(
        generated,
        anyOf(
          contains('StackedNavigatorGenerator'),
          contains('StackedRouterGenerator'),
        ));
    expect(generated, contains("import 'package:flutter/material.dart'"));
    expect(generated, contains("import 'package:stacked/stacked.dart'"));
  });

  test('emits a Routes class with a path constant per annotated route', () {
    // Routes.homeView = '/'   → the initial route's path
    // Routes.detailsView      → a helper producing '/details/<id>'
    expect(generated, contains('class Routes'));
    expect(generated, contains("homeView = '/'"));
    expect(generated, contains("detailsView"));
    expect(generated, contains(r'/details/:id'));
  });

  test('registers both HomeView and DetailsView in the RouteDef list', () {
    // StackedRouter.`_routes` carries a `RouteDef(page: HomeView)` /
    // `RouteDef(page: DetailsView)` pair, one per MaterialRoute entry.
    expect(generated, contains('RouteDef'));
    expect(generated, contains('page: _i2.HomeView'));
    expect(generated, contains('page: _i2.DetailsView'));
  });

  test('wires StackedRouter with a _pagesMap for MaterialPageRoute factories',
      () {
    // The generator emits a `_pagesMap` mapping each page Type to a
    // `StackedRouteFactory`. MaterialRoute(...) annotations must yield
    // `MaterialPageRoute` factories (vs CupertinoRoute / etc.).
    expect(generated, contains('class StackedRouter'));
    expect(generated, contains('_pagesMap'));
    expect(generated, contains('MaterialPageRoute'));
  });
}
