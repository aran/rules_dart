// Both parts of this library are hand-written, despite their names, so Bazel
// records them as sources and `dart_fix`'s own protection never engages. What
// is left is `dart fix`'s built-in generated-file skip, and the two parts carry
// the same violation so that only the file name can account for the difference.
part 'thing.freezed.dart';
part 'thing.g.dart';

String thing() => '${fromG()} ${fromFreezed()}';
