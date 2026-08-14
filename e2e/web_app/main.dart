import 'dart:js_interop';

import 'package:characters/characters.dart';
import 'package:greet/greet.dart';
import 'package:web_app/root_greet.dart';

import 'config.dart';

// `js_output_test` asserts these strings survive into the compiled app.js, so
// the sink has to be one the compiler cannot see through: an external call's
// arguments are never tree-shaken. (`print` would do too, but it is what
// `avoid_print` forbids, and on the web it lowers to this anyway.)
@JS('console.log')
external void _log(JSString message);

void main() {
  _log('$appName v$appVersion'.toJS);
  _log(greet('JavaScript').toJS);
  _log(rootGreet().toJS);
  _log(const String.fromEnvironment('banner').toJS);
  _log('flag count: ${'🇨🇦'.characters.length}'.toJS);
}
