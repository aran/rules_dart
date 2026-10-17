import 'package:path/path.dart' as p;

/// Joins an id onto the `ids` directory. Imports `package:path`, which only the
/// wrapping library declares.
String idPath(String id) => p.join('ids', id);
