// Minimal input for the codegen regression fixture. Its content is
// incidental: `//codegen/tools:lib_gen` emits a fixed `.g.dart` regardless. The
// point of this package is that the codegen action resolves a Dart SDK even
// when the build's target platform has no registered Dart toolchain.
class Model {}
