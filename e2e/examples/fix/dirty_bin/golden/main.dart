// A `dart_binary` entrypoint with a `prefer_final_locals` violation, beside
// `lib/` rather than inside it — the shape no `dart_library` will accept, which
// reaches the fixes only as an executable's own file.
//
// `golden/main.dart` is what `dart fix` must turn this into, byte for byte, so
// the two files differ only by `final` against `var`. Keep everything else in
// step.
import 'package:fix_bin_dep/dep.dart';

void main() {
  final label = binLabel();
  print('running $label');
}
