import 'package:go_router_builder/go_router_builder.dart' show goRouterBuilder;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, goRouterBuilder);
