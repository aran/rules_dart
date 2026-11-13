import 'dart:ffi';

/// A binding to the native code the package's hook would build.
@Native<Int32 Function()>()
external int answer();
