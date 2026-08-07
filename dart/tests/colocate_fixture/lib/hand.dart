// A hand-written source in the same package as the generated one below it, so
// the package straddles the source tree and bazel-out and `colocate_packages`
// has to assemble it. The package also owns a code asset — that combination is
// the whole point of the fixture.
String get handWritten => 'hand';
