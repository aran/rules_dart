# dart_package_metadata_twice

A package has one `dart_package_metadata`, as it has one `pubspec.yaml`.
Gazelle says so where the BUILD file at the package's root holds two, rather
than merging into one of them, and writes nothing.
