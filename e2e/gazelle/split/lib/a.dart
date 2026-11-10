import 'package:split/src/util/util.dart';

import 'src/model/model.dart';

/// Describes a [Model] made from [name].
String describe(String name) => shout(Model(name).toString());
