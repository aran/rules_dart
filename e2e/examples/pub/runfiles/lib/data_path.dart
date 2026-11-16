import 'package:runfiles/runfiles.dart';

/// The path of [file], looked up the way a package with `runfiles` in its
/// pubspec does.
String dataPath(String file) => Runfiles.create().rlocation(file);
