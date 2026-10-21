import 'package:fine_module_fixture/src/pool_workers.dart';

void main() {
  if (poolWorkers() != 4) throw StateError('${poolWorkers()}');
}
