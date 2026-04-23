import 'package:injectable/injectable.dart';

// Distinct @injectable class used only by the primitive-form pipeline.
// Separate from `Greeter` so the two BUILD pipelines don't collide on
// output paths (each `shim_metadata` emits at `<src>.injectable.json`).
@injectable
class PrimitiveGreeter {
  String greet(String who) => 'primitive-hello, $who';
}
