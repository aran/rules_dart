# dart_package_metadata

Gazelle writes a `dart_package_metadata` at each package root that has a fact
to state, and every rule it writes for the package names it with `package`,
including the binaries of `bin/` and the tests of `test/` and the directories
under it (`//app:pubspec-metadata`).

- `app/`: its name and language version from `pubspec.yaml`, and its license
  file, `NOTICES`, which wins over the `LICENSE` beside it, as
  `pub.from_lock()` and `flutter build` choose.
- `licensed/`: `LICENSE`, with no `NOTICES`.
- `mixed_case/`: a file named `License` is neither, by exact name, so it
  states no license; with no pubspec it has no fact, so it has no metadata,
  and its rules name none: the rules name it after its directory.
- `unstated/`: nothing states a fact, so it has no metadata and its library
  and test name none.
- `pubspec/`: a package named `pubspec`, whose library has that name. The
  metadata is named `pubspec-metadata` in every package, which no library can
  be.
