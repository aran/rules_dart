// A test in the package of its library. Its `package:` import of that library
// has no source in the staged project: summary mode resolves it from the
// library's summary, which is how this test is analyzed.
import 'package:testpkg_fixture/testpkg.dart';

void main() {
  print(testpkgValue());
}
