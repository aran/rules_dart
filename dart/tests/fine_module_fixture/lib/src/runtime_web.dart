import 'dart:js_interop';

import 'pool_workers.dart';

@JS('globalThis')
external JSObject get globalObject;

int webWorkers() => poolWorkers() + 1;
