# runfiles

Bazel [runfiles](https://bazel.build/extending/rules#runfiles) library for Dart.
Locates data files at runtime in both directory-based and manifest-based modes.

This package is part of [rules_dart](https://github.com/aran/rules_dart).

## Usage

### Binary in the main Bazel module

This is the common case — a `dart_binary` target declared inside your
project's main module. Use the no-arg constructor; the default source
repository (`''`, main module) makes apparent → canonical name lookups
resolve correctly under bzlmod.

```dart
import 'package:runfiles/runfiles.dart';

void main() {
  final r = Runfiles.create();
  final path = r.rlocation('my_dep/path/to/data.txt');
  print(File(path).readAsStringSync());
}
```

### Binary shipped as a Bazel dep of another module

Rare, but if your `dart_binary` itself ships as a Bazel module that other
modules depend on, pass your canonical repo name so apparent-name
lookups in `rlocation` resolve from your module's perspective:

```dart
final r = Runfiles.create(sourceRepository: 'my_module+');
```

### Library code that calls `rlocation`

Library code that resolves runfiles needs to look them up from *its own*
module's perspective, not the calling binary's. Hold a `forRepo` view
keyed to your library's canonical repo:

```dart
import 'package:runfiles/runfiles.dart';

const String _myCanonicalRepo = 'my_lib+';

class WidgetLoader {
  final Runfiles _runfiles;
  WidgetLoader(Runfiles binaryRunfiles)
      : _runfiles = binaryRunfiles.forRepo(_myCanonicalRepo);

  String loadTemplate() =>
      _runfiles.rlocation('baz/templates/index.html');
}
```

This matters under bzlmod when two modules disagree on the version of a
shared dependency: each module's `rlocation('baz/...')` must resolve
through its own row of the `_repo_mapping` table to pick the correct
canonical repo.

**Caveat:** under `multiple_version_override`, the canonical name embeds
a version suffix (`my_lib+1.0` vs. `my_lib+2.0`), and a hardcoded const
can't tell which version it's compiled as. If you hit that case, file
an issue on rules_dart.
