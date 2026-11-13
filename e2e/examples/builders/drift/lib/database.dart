import 'package:drift/drift.dart';
import 'package:drift_fixture/posts_dao.dart';

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
enum PostKind {
  /// A broadcast announcement.
  announcement,

  /// An open discussion.
  discussion,

  /// A question awaiting answers.
  question,
}

/// Converts [PostKind] to and from its SQL string form.
class PostKindConverter extends TypeConverter<PostKind, String> {
  /// Const-constructible so `.map()` can constant-evaluate it.
  const PostKindConverter();

  @override
  PostKind fromSql(String fromDb) => PostKind.values.byName(fromDb);

  @override
  String toSql(PostKind value) => value.name;
}

/// The users table (schema-in-Dart).
class Users extends Table {
  /// Auto-incrementing primary key.
  IntColumn get id => integer().autoIncrement()();

  /// The user's name.
  TextColumn get name => text()();
}

/// The posts table, with a FK to [Users] and a converter column.
class Posts extends Table {
  /// Auto-incrementing primary key.
  IntColumn get id => integer().autoIncrement()();

  /// The authoring user's id.
  IntColumn get userId => integer().references(Users, #id)();

  /// The post's title.
  TextColumn get title => text()();

  /// The post's kind, stored via [PostKindConverter].
  TextColumn get kind => text().nullable().map(const PostKindConverter())();
}

/// The exemplar database over Dart- and SQL-defined tables.
@DriftDatabase(
  tables: [Users, Posts],
  daos: [PostsDao],
  include: {'database.drift'},
)
class AppDatabase extends _$AppDatabase {
  // The parameter name mirrors the generated `_$AppDatabase(QueryExecutor e)`
  // it forwards to; a super-parameter has to match the name upstream.

  /// Opens the database on executor [e].
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;
}
