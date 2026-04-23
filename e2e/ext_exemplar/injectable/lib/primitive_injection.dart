import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'primitive_injection.config.dart';

// Primitive-form @InjectableInit. Drives a separate GetIt registration
// entry point from the macro form so both pipelines can coexist in this
// exemplar without sharing output paths. The primitive pipeline only
// covers `@injectable` — its purpose is proving the raw
// dart_codegen + dart_aggregate_codegen pair still wire up a working
// GetIt; the comprehensive annotation coverage is in the macro-form
// test.
@InjectableInit(initializerName: r'$initPrimitiveGetIt')
void configurePrimitiveInjection() =>
    GetIt.instance.$initPrimitiveGetIt();
