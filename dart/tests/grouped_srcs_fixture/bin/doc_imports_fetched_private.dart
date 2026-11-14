/// @docImport 'package:collection/src/utils.dart';
library;

import 'dart:io';

import 'package:collection/collection.dart';

void main() => stdout.writeln(const ListEquality<int>().equals([1], [1]));
