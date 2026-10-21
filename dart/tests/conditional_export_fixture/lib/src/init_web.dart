import 'package:cond_dep/cond_dep.dart';

import 'web_helper.dart';

String platform() => 'web:${WebThing()}${helper()}';
