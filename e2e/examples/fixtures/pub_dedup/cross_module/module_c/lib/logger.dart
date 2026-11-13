import 'package:logging/logging.dart';

/// Uses a package that only `module_c`'s lock names, through a hub whose name
/// the root module also uses.
String describe(String name) => Logger(name).fullName;
