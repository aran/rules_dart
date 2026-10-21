import 'package:toolchain_inner/inner.dart';
import 'package:toolchain_runtime/runtime.dart';

String usesRuntime() => 'uses ${fromRuntime()} and ${inner()}';
