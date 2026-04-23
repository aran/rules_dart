import 'package:get_it/get_it.dart';
import 'package:injectable_fixture/primitive_greeter.dart';
import 'package:injectable_fixture/primitive_injection.dart';
import 'package:test/test.dart';

// Exercises the primitive-form injectable pipeline (hand-wired
// dart_codegen for stage 1 + dart_aggregate_codegen for stage 2). A
// regression in the primitive path would flip this test without
// affecting the macro-form `macro_injection_test`.

void main() {
  tearDown(() async {
    await GetIt.instance.reset();
  });

  test('primitive-form pipeline registers an @injectable class with GetIt',
      () {
    configurePrimitiveInjection();
    expect(GetIt.instance.get<PrimitiveGreeter>().greet('world'),
        'primitive-hello, world');
  });
}
