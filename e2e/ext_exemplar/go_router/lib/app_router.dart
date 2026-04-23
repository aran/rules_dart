import 'package:go_router/go_router.dart';

part 'app_router.g.dart';

// Type-safe route tree with one nested level. `HomeRoute` sits at `/`,
// `DetailsRoute` at `/details/:id` takes an `id` path parameter. The
// `extra` field is a go_router-builder convention for passing non-path
// state through the route.
//
// go_router_builder matches @TypedGoRoute via
// TypeChecker.fromUrl('package:go_router/src/route_data.dart#TypedGoRoute')
// and emits: a top-level `$appRoutes` list, per-route `GoRouteData.$route`
// initializers, mixin extensions (`$HomeRoute`, `$DetailsRoute`) on each
// route class. The mixins live in the generated part file, so each route
// class mixes them in via `with $RouteName`.

@TypedGoRoute<HomeRoute>(
  path: '/',
  routes: [
    TypedGoRoute<DetailsRoute>(path: 'details/:id'),
  ],
)
class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();
}

class DetailsRoute extends GoRouteData with $DetailsRoute {
  const DetailsRoute({required this.id, this.extra});

  final String id;
  final String? extra;
}
