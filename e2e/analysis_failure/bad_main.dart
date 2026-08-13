/// The entrypoint half of this workspace's red path. `dart_binary`'s `main`
/// lives under no `lib/`, so it reaches the analyzer through
/// `DartAnalyzableInfo`; the unused import is the diagnostic that proves the
/// entrypoint is genuinely analyzed rather than merely staged.
///
/// A different diagnostic from `lib/bad.dart`'s deliberately: the CI harness
/// greps each target's output for its own error, and two targets sharing one
/// string would let either check pass on the other's failure.
import 'dart:convert';

void main() {
  print('unreachable');
}
