# runfiles

Bazel [runfiles](https://bazel.build/extending/rules#runfiles) library for Dart.
Locates data files at runtime in both directory-based and manifest-based modes.

This package is part of [rules_dart](https://github.com/aran/rules_dart).

## Usage

```dart
import 'package:runfiles/runfiles.dart';

void main() {
  final r = Runfiles.create();
  final path = r.rlocation('my_workspace/path/to/data.txt');
  print(File(path).readAsStringSync());
}
```
