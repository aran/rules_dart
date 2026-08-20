import 'package:drift/drift.dart';
import 'package:drift_fixture/database.dart';

part 'posts_dao.g.dart';

// Describes a Post joined with its author's name. Returned by
// [PostsDao.postsWithAuthor] below.

/// A [Post] paired with its author's name.
class PostWithAuthor {
  /// Creates the pair.
  PostWithAuthor({required this.post, required this.author});

  /// The post entity.
  final Post post;

  /// The author's name.
  final String author;
}

// DAO scoped to the Posts table. drift_dev emits `_$PostsDaoMixin` into
// the part file above, giving table accessors + the query DSL scoped
// to this accessor. Consumers call `db.postsDao.forUser(id)` and
// `db.postsDao.postsWithAuthor(id)`.

/// Queries over [Posts], attached to [AppDatabase].
@DriftAccessor(tables: [Posts, Users])
class PostsDao extends DatabaseAccessor<AppDatabase> with _$PostsDaoMixin {
  /// Creates the DAO on [attachedDatabase].
  PostsDao(super.attachedDatabase);

  /// All posts authored by [userId].
  Future<List<Post>> forUser(int userId) {
    return (select(posts)..where((t) => t.userId.equals(userId))).get();
  }

  // Multi-table join using drift's Dart DSL. Returns a custom row type
  // combining the full Post entity with a single extra field from Users.

  /// Posts authored by [userId], each joined with the author's name.
  Future<List<PostWithAuthor>> postsWithAuthor(int userId) async {
    final query = select(posts).join([
      innerJoin(users, users.id.equalsExp(posts.userId)),
    ])
      ..where(users.id.equals(userId));

    return (await query.get())
        .map((row) => PostWithAuthor(
              post: row.readTable(posts),
              author: row.readTable(users).name,
            ))
        .toList();
  }
}
