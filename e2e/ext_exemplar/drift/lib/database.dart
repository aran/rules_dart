import 'package:drift/drift.dart';

import 'posts_dao.dart';

part 'database.g.dart';

// Comprehensive drift exemplar. Five feature clusters:
//
//   1. `include: {'database.drift'}` — SQL-defined `todos` table + the
//      `AS Todo` data class + named query `allTodos` pulled in from a
//      companion .drift file.
//   2. Dart-side `Table` subclasses (Users, Posts) — schema-in-Dart
//      with a FK from Posts to Users.
//   3. `TypeConverter<PostKind, String>` — a Dart-defined converter
//      attached to a column via `.map(const PostKindConverter())`.
//      drift's analyzer reads the `.map()` argument, constant-evaluates
//      it to the converter instance, and emits a
//      `GeneratedColumnWithTypeConverter<PostKind, String>`.
//   4. `daos: [PostsDao]` — accessor class in posts_dao.dart that
//      encapsulates queries over Posts.
//   5. A multi-table join in a `.drift` named query that references the
//      Dart-defined tables via `import 'database.dart';`.
//
// Exercises drift's full pipeline (prep + discover + analyzer +
// driftBuilder) in both cross-file modes: Dart ↔ .drift and Dart ↔ Dart.

/// Persisted as its `.name` via [PostKindConverter].
enum PostKind { announcement, discussion, question }

class PostKindConverter extends TypeConverter<PostKind, String> {
  const PostKindConverter();

  @override
  PostKind fromSql(String fromDb) => PostKind.values.byName(fromDb);

  @override
  String toSql(PostKind value) => value.name;
}

class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
}

class Posts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get userId => integer().references(Users, #id)();
  TextColumn get title => text()();
  TextColumn get kind => text().nullable().map(const PostKindConverter())();
}

@DriftDatabase(
  tables: [Users, Posts],
  daos: [PostsDao],
  include: {'database.drift'},
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 1;
}
