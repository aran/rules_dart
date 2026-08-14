import 'package:get_it/get_it.dart';
import 'package:injectable_fixture/_init_counter.dart' as counter;
import 'package:injectable_fixture/api_client.dart';
import 'package:injectable_fixture/config.dart';
import 'package:injectable_fixture/database_service.dart';
import 'package:injectable_fixture/greeter.dart';
import 'package:injectable_fixture/injection.dart';
import 'package:test/test.dart';

// Exercises the macro-form injectable pipeline (`injectable_library`).
// The primitive-form equivalent lives in `primitive_injection_test.dart`
// and re-asserts the same contract against hand-wired dart_codegen
// targets, guarding macro↔primitive equivalence.

void main() {
  tearDown(() async {
    await GetIt.instance.reset();
    counter.apiClientInitCount = 0;
  });

  test('@injectable class (factory scope) registers and resolves', () {
    configureInjection();
    final g1 = GetIt.instance.get<Greeter>();
    expect(g1.greet('world'), 'hello, world');
    // Factory-scoped: each `get` returns a fresh instance.
    final g2 = GetIt.instance.get<Greeter>();
    expect(identical(g1, g2), isFalse);
  });

  test('@singleton returns the identical instance across gets', () {
    configureInjection();
    final d1 = GetIt.instance.get<DatabaseService>()..pings = 3;
    final d2 = GetIt.instance.get<DatabaseService>();
    expect(identical(d1, d2), isTrue);
    expect(d2.pings, 3);
  });

  test('@lazySingleton defers construction until first get', () {
    expect(counter.apiClientInitCount, 0);
    configureInjection();
    // Still zero — not instantiated just by configureInjection.
    expect(counter.apiClientInitCount, 0);

    final a1 = GetIt.instance.get<ApiClient>();
    expect(counter.apiClientInitCount, 1);
    final a2 = GetIt.instance.get<ApiClient>();
    expect(counter.apiClientInitCount, 1, reason: 'second get must reuse');
    expect(identical(a1, a2), isTrue);
  });

  test('@module + @Named exposes a third-party-value registration', () {
    configureInjection();
    final t = GetIt.instance.get<DateTime>(instanceName: 'build-time');
    expect(t, DateTime.utc(2024));
  });

  test('@Environment filters which implementation registers', () {
    configureInjection(env: 'dev');
    final cfg = GetIt.instance.get<AppConfig>();
    expect(cfg, isA<DevConfig>());
    expect(cfg.label, 'dev-config');
  });

  test('a different @Environment resolves a different implementation',
      () async {
    configureInjection(env: 'prod');
    final cfg = GetIt.instance.get<AppConfig>();
    expect(cfg, isA<ProdConfig>());
    expect(cfg.label, 'prod-config');
  });
}
