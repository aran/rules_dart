/// Pure-Dart stub of `package:go_router`'s annotation surface.
///
/// The real `go_router` package pulls in Flutter (`package:flutter/widgets.dart`
/// via `src/route_data.dart`) and therefore cannot be depended on directly in
/// rules_dart's pure-Dart test environment. But `go_router_builder`'s annotation
/// matching is URL-based — `TypeChecker.fromUrl('package:go_router/src/route_data.dart#TypedGoRoute')`
/// (see go_router_builder-4.3.0/lib/src/go_router_generator.dart:15) — so the
/// analyzer only needs to resolve a class at that URL; it doesn't need the
/// class to have Flutter-dependent behavior.
///
/// This stub declares exactly the classes go_router_builder's generator reads
/// via its TypeCheckers. The generated output of go_router_builder still
/// imports `package:flutter/material.dart` and `package:go_router/go_router.dart`
/// and therefore cannot be compiled in pure-Dart — but the rules_dart test
/// doesn't compile it; it reads it as a string via runfiles and asserts
/// structure. Same pattern used for stacked's Flutter-bound sub-builder outputs.

export 'src/route_data.dart';
