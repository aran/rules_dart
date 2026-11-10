import 'package:subdir_package_fixture/src/util/util.dart';

import 'src/model/model.dart';

/// Describes a [Model] made from [name].
String describe(String name) => shout(Model(name).toString());
