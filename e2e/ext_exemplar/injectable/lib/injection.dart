import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'injection.config.dart';

// @InjectableInit drives stage 2 — the aggregate `dart_aggregate_codegen`
// action reads every `.injectable.json` metadata shard and emits
// `injection.config.dart` + `injection.module.dart`.
//
// The environment: parameter on the generated $initGetIt takes a string
// (or null) and filters which @Environment-gated classes register.
@InjectableInit(initializerName: r'$initGetIt')
void configureInjection({String? env}) => GetIt.instance.$initGetIt(
      environment: env,
    );
