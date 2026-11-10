import 'dart:io';

import 'package:subdir_package_fixture/a.dart';

void main(List<String> args) =>
    stdout.writeln(describe(args.isEmpty ? ' x ' : args.first));
