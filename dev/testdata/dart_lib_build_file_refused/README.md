# dart_lib_build_file_refused

A BUILD file under a package's `lib/` would cut the package's `dart_library`,
at its root, off from the files below it. One that holds a rule Gazelle did
not write, or a directive, is an error naming it, and Gazelle writes nothing:
deleting it would lose what it holds.
