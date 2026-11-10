# Gazelle: generated files in the source tree

A package's source tree can hold the files its builders generate, as a
published package must (`lib/user.g.dart`, `lib/user.freezed.dart`). Gazelle
leaves out of every `srcs` each file a codegen target it writes produces:
`user.g.dart`, which the codegen of `user.dart` generates. Every other file is
a source, whatever its name: no target here produces `user.freezed.dart`,
since `user.dart` carries no `@freezed`, so it is in the package's library.
