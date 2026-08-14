import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_fixture/database.dart';
import 'package:test/test.dart';

// No FFI ceremony: the BUILD's `code_assets = [sqlite3_code_asset()]` embeds
// the Bazel-built libsqlite3 into the test kernel as a code asset, so
// `package:sqlite3`'s `@Native` bindings resolve against it. This source is
// identical to a plain (non-Bazel) drift test.

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('.drift-defined schema + named query', () {
    test('todos round-trip via the SQL-defined table', () async {
      await db
          .into(db.todos)
          .insert(TodosCompanion.insert(title: 'milk', body: 'two litres'));
      await db
          .into(db.todos)
          .insert(TodosCompanion.insert(title: 'eggs', body: 'a dozen'));

      // `allTodos` is a named query defined in database.drift — proves the
      // .drift file was reached by the drift builder's full 4-stage
      // pipeline (prep + discover + analyzer + driftBuilder).
      final all = await db.allTodos().get();
      expect(all, isA<List<Todo>>());
      expect(all.map((t) => t.title), ['milk', 'eggs']);
    });
  });

  group('Dart-defined tables with FK', () {
    test('Posts references Users via foreign-key column', () async {
      final userId = await db
          .into(db.users)
          .insert(UsersCompanion.insert(name: 'Aria'));
      await db
          .into(db.posts)
          .insert(PostsCompanion.insert(userId: userId, title: 'Welcome'));

      final post = await db.select(db.posts).getSingle();
      expect(post.userId, userId);
      expect(post.title, 'Welcome');
    });
  });

  group('TypeConverter<PostKind, String>', () {
    test('Post.kind round-trips through PostKindConverter', () async {
      final userId = await db
          .into(db.users)
          .insert(UsersCompanion.insert(name: 'Aria'));
      await db
          .into(db.posts)
          .insert(
            PostsCompanion.insert(
              userId: userId,
              title: 'Welcome',
              kind: const Value(PostKind.announcement),
            ),
          );

      final post = await db.select(db.posts).getSingle();
      // The @map(const PostKindConverter()) call on Posts.kind must yield
      // a `PostKind` on read and accept a `PostKind` on write. drift's
      // analyzer is responsible for recognising the `.map(...)` argument
      // as a TypeConverter subtype and wiring the column's Dart type
      // accordingly.
      expect(post.kind, PostKind.announcement);
    });
  });

  group('@DriftAccessor DAO', () {
    test('PostsDao.forUser returns only posts for the given user', () async {
      final aliceId = await db
          .into(db.users)
          .insert(UsersCompanion.insert(name: 'Alice'));
      final bobId = await db
          .into(db.users)
          .insert(UsersCompanion.insert(name: 'Bob'));

      await db
          .into(db.posts)
          .insert(
            PostsCompanion.insert(userId: aliceId, title: "Alice's first"),
          );
      await db
          .into(db.posts)
          .insert(
            PostsCompanion.insert(userId: aliceId, title: "Alice's second"),
          );
      await db
          .into(db.posts)
          .insert(PostsCompanion.insert(userId: bobId, title: "Bob's note"));

      final alices = await db.postsDao.forUser(aliceId);
      expect(
        alices.map((p) => p.title).toSet(),
        equals({"Alice's first", "Alice's second"}),
      );

      final bobs = await db.postsDao.forUser(bobId);
      expect(bobs, hasLength(1));
      expect(bobs.first.title, "Bob's note");
    });
  });

  group('multi-table join via DAO DSL', () {
    test(
      'postsWithAuthor returns each post paired with its author name',
      () async {
        final aliceId = await db
            .into(db.users)
            .insert(UsersCompanion.insert(name: 'Alice'));
        await db
            .into(db.posts)
            .insert(PostsCompanion.insert(userId: aliceId, title: 'Hello'));
        await db
            .into(db.posts)
            .insert(PostsCompanion.insert(userId: aliceId, title: 'World'));

        final rows = await db.postsDao.postsWithAuthor(aliceId);
        expect(rows, hasLength(2));
        expect(rows.every((r) => r.author == 'Alice'), isTrue);
        expect(
          rows.map((r) => r.post.title).toSet(),
          equals({'Hello', 'World'}),
        );
      },
    );
  });

  group('multi-table join via .drift named query', () {
    test(
      'postsByUser joins posts with users.name via the .drift SELECT',
      () async {
        final aliceId = await db
            .into(db.users)
            .insert(UsersCompanion.insert(name: 'Alice'));
        await db
            .into(db.posts)
            .insert(PostsCompanion.insert(userId: aliceId, title: 'Hello'));

        // `postsByUser` is defined in database.drift. It references
        // Dart-declared Users / Posts tables via the `.drift` file's
        // `import 'database.dart';` directive. drift_dev must cross the
        // Dart ↔ .drift boundary to emit the generated query method.
        final rows = await db.postsByUser(aliceId).get();
        expect(rows, hasLength(1));
        expect(rows.first.author, 'Alice');
        expect(rows.first.title, 'Hello');
      },
    );
  });
}
