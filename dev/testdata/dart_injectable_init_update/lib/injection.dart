import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'injection.config.dart';

@InjectableInit(initializerName: r'$initGetIt')
void configureInjection() => GetIt.instance.$initGetIt();
