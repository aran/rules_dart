import 'package:drift/drift.dart';

part 'store.g.dart';

class Entries extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get at => dateTime()();
}

@DriftDatabase(tables: [Entries])
class Store extends _$Store {
  Store(super.e);

  @override
  int get schemaVersion => 1;
}
