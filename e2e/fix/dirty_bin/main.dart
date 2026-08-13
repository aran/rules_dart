// A `dart_binary` entrypoint with a `prefer_final_locals` violation, beside
// `lib/` rather than inside it — the shape no `dart_library` will accept and so
// the shape nothing could fix before `dart_fix` learned to take an executable.
//
// `golden/main.dart` is what `dart fix` must turn this into, byte for byte, so
// the two files differ only by `final` against `var`. Keep everything else in
// step.
import 'package:fix_bin_dep/dep.dart';

void main() {
  var label = binLabel();
  print('running $label');
}
