// A helper, not a test: package:test runs only files ending in `_test.dart`.
import 'package:codegen/event.dart';
import 'package:codegen/profile.dart';
import 'package:codegen/user.dart';

/// A user every test starts from.
final user = User(id: 7, name: 'Ada');

/// A profile every test starts from.
final profile = Profile(handle: 'ada', bio: 'engines');

/// An event every test starts from.
const event = Event(type: 'click', sequence: 42);
