/// A second `lib/` source, importing its sibling by `package:` URI.
///
/// The entrypoint's self-import is only half the shape: a package's `lib/`
/// files import *each other* the same way, and that resolution is what a
/// package-less closure breaks for every file at once rather than only for the
/// one the entrypoint names.
import 'package:analyzable_pkg/model.dart';

String describe(Model model) => 'model: ${model.name}';
