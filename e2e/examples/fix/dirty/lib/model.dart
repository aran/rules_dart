// Half of a before/after pair: `dart fix` has to turn dirty/lib/model.dart into
// clean/lib/model.dart byte for byte, so the two files differ only by the
// `@override` and by `final` against `var`. Keep everything else in step.
//
// Neither fix can be proposed unless the generated parts resolved: `ModelBase`
// and `modelLabel` are declared in the files the fix rule excludes.
part 'model.freezed.dart';
part 'model.g.dart';

class Model extends ModelBase {
  String describe() {
    var label = modelLabel();
    return 'model: $label';
  }
}
