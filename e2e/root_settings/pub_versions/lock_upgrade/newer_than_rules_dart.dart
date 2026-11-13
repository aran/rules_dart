import 'dart:io';

import 'package:get_it/get_it.dart';

// Builds only if get_it resolves to this workspace's version rather than the
// older one in rules_dart's own tool lock.
void main() {
  GetIt.instance.registerSingleton<String>('resolved');
  stdout.writeln('get_it: ${GetIt.instance<String>()}');
}
