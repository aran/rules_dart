// The test `starlark_docs_test` makes: every public symbol of a package's .bzl
// files is documented. Arguments: the runfiles paths of the `ModuleInfo`
// (`<target>.binaryproto`) `starlark_doc_extract` writes for each file.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'starlark_docs.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final gaps = [
    for (final path in args)
      if (ProtoMessage.decode(File(runfiles.rlocation(path)).readAsBytesSync())
          case final module)
        for (final gap in undocumented(module))
          '${module.string(moduleFile)}: $gap has no documentation',
  ];
  if (gaps.isEmpty) return;
  gaps.forEach(stderr.writeln);
  exitCode = 1;
}
