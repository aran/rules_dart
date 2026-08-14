import 'package:stacked_shared/stacked_shared.dart';

import 'services.dart';

// Populated @StackedApp touching every sub-builder:
//   - routes: two MaterialRoute entries (root + nested path param)
//   - dependencies: two @LazySingleton services
//   - dialogs: one registration
//   - bottomsheets: one registration
//   - logger: a StackedLogger config with a non-default helper name
//
// The `classType: ...` fields reference pure-Dart stub classes declared
// alongside this file. At analyzer time stacked_generator only reads
// type names and declaration sites — it doesn't demand that the classes
// extend any Flutter base type — so these stubs keep the source
// Flutter-free. The *generated* outputs (.router.dart, .dialogs.dart,
// .bottomsheets.dart, .logger.dart) do import package:flutter, which is
// why those aren't compiled in a dart_library. They're read as strings
// by the runfiles-structural tests in `test/`.

@StackedApp(
  routes: [
    MaterialRoute(page: HomeView, initial: true),
    MaterialRoute(page: DetailsView, path: '/details/:id'),
  ],
  dependencies: [
    // The type argument is inert to stacked_generator, which reads
    // `classType`; it is spelled out because the annotation is a constructor
    // call and nothing else can infer `T`.
    LazySingleton<GreetingService>(classType: GreetingService),
    LazySingleton<CounterService>(classType: CounterService),
  ],
  dialogs: [
    StackedDialog(classType: InfoDialog),
  ],
  bottomsheets: [
    StackedBottomsheet(classType: ConfirmSheet),
  ],
  logger: StackedLogger(logHelperName: 'getFixtureLogger'),
)
class App {}

class HomeView {}

class DetailsView {}

class InfoDialog {}

class ConfirmSheet {}
