import 'dart:io';

import 'package:app/app.dart';

/// Prints the message, and writes it to the file named by the one argument.
void main(List<String> args) {
  final line = message();
  stdout.writeln(line);
  if (args.isNotEmpty) File(args.single).writeAsStringSync('$line\n');
}
