// Pure-Dart stubs mirroring the classes go_router_builder reads via
// TypeChecker.fromUrl(...). Only the names and declared type parameters
// matter to the generator — it never invokes methods on these classes.

/// Annotation marking a type-safe route. Applied to subclasses of [GoRouteData].
class TypedGoRoute<T extends GoRouteData> {
  const TypedGoRoute({
    required this.path,
    this.name,
    this.caseSensitive = true,
    this.routes = const <TypedGoRoute<GoRouteData>>[],
  });

  final String path;
  final String? name;
  final bool caseSensitive;
  final List<TypedGoRoute<GoRouteData>> routes;
}

/// Base class for classes annotated with [TypedGoRoute].
abstract class GoRouteData {
  const GoRouteData();
}

/// Annotation marking a type-safe relative route.
class TypedRelativeGoRoute<T extends RelativeGoRouteData> {
  const TypedRelativeGoRoute({
    required this.path,
    this.name,
    this.caseSensitive = true,
  });

  final String path;
  final String? name;
  final bool caseSensitive;
}

/// Base class for classes annotated with [TypedRelativeGoRoute].
abstract class RelativeGoRouteData {
  const RelativeGoRouteData();
}

/// Annotation marking a type-safe shell route.
class TypedShellRoute<T extends ShellRouteData> {
  const TypedShellRoute({
    this.routes = const <TypedGoRoute<GoRouteData>>[],
  });

  final List<TypedGoRoute<GoRouteData>> routes;
}

/// Base class for classes annotated with [TypedShellRoute].
abstract class ShellRouteData {
  const ShellRouteData();
}

/// Annotation marking a type-safe stateful shell route.
class TypedStatefulShellRoute<T extends StatefulShellRouteData> {
  const TypedStatefulShellRoute({
    this.branches = const <TypedStatefulShellBranch<StatefulShellBranchData>>[],
  });

  final List<TypedStatefulShellBranch<StatefulShellBranchData>> branches;
}

/// Base class for classes annotated with [TypedStatefulShellRoute].
abstract class StatefulShellRouteData {
  const StatefulShellRouteData();
}

/// Branch of a stateful shell route.
class TypedStatefulShellBranch<T extends StatefulShellBranchData> {
  const TypedStatefulShellBranch({
    this.routes = const <TypedGoRoute<GoRouteData>>[],
  });

  final List<TypedGoRoute<GoRouteData>> routes;
}

/// Base class for branches of stateful shell routes.
abstract class StatefulShellBranchData {
  const StatefulShellBranchData();
}
