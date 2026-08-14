import 'package:drift/drift.dart';

import 'database.dart';

part 'posts_dao.g.dart';

// Describes a Post joined with its author's name. Returned by
// [PostsDao.postsWithAuthor] below.
class PostWithAuthor {
  PostWithAuthor({required this.post, required this.author});
  final Post post;
  final String author;
}

// DAO scoped to the Posts table. drift_dev emits `_$PostsDaoMixin` into
// the part file above, giving table accessors + the query DSL scoped
// to this accessor. Consumers call `db.postsDao.forUser(id)` and
// `db.postsDao.postsWithAuthor(id)`.
@DriftAccessor(tables: [Posts, Users])
class PostsDao extends DatabaseAccessor<AppDatabase> with _$PostsDaoMixin {
  PostsDao(super.attachedDatabase);

  Future<List<Post>> forUser(int userId) {
    return (select(posts)..where((t) => t.userId.equals(userId))).get();
  }

  // Multi-table join using drift's Dart DSL. Returns a custom row type
  // combining the full Post entity with a single extra field from Users.
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
