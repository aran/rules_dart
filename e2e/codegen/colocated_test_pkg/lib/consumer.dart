import 'package:import_fixture/via_package.dart';

/// A pure-source library — nothing here is generated — whose dependency does
/// carry generated members.
String consume() => viaPackage();
