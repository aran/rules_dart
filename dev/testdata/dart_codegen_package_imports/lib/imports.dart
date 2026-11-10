import 'package:collection/collection.dart';

import 'src/helper.dart';
import 'user.dart';

String names(List<User> users) => users.map((u) => u.name).join(',');
