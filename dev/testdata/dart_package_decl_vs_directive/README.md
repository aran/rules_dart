# dart_package_decl_vs_directive

A `# gazelle:dart_package_name` directive and a `dart_package_metadata` in the
same directory naming different packages. One fact stated twice must agree, so
Gazelle fails, naming both values and where each is stated, and writes no
BUILD file.
