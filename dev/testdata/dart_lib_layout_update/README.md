# dart_lib_layout_update

A package whose BUILD files earlier Gazelle versions wrote, one per directory
under `lib/`: a `dart_library` for each directory, and a `filegroup` for each
directory of an import cycle, lent to the library of another. Gazelle writes
the package's one `dart_library` at its root, holding every file under `lib/`,
moves the codegen of an annotated source in a subdirectory there, named for
its path under `lib/`, and empties the old BUILD files, which it then deletes.
A checked-in file a codegen target produces stays out of `srcs`; one no target
produces is a source, whatever its name.
