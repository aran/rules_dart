# dart_parts

The import check follows `part` as it follows `import` and `export`, so a
program's parts are in its `srcs`. Under the `enhanced-parts` language experiment
a part may have imports and parts of its own, so those are followed too, and what
it imports is in the program's `deps`. A part is no program: it gets
no `dart_test` or `dart_binary` whatever its name, and those earlier versions
wrote for one are deleted. A script's `main` may be in one of its parts.
