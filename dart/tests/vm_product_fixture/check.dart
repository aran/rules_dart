// Fails unless `dart.vm.product` is false in the test's own files and in its
// dependency's module, as it is under `dart test`, which runs the VM that is
// not a product one.
import 'package:vm_product_fixture/mode.dart' as mode;

void main() {
  const own = bool.fromEnvironment('dart.vm.product');
  if (own || mode.product) {
    throw StateError(
      '`dart.vm.product` is true under test (own: $own, dependency: '
      '${mode.product}); `dart test` sees it false',
    );
  }
}
