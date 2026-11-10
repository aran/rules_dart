import 'package:layout/src/a/a.dart';

String b(String s) => s.isEmpty ? s : a(s.substring(1));
