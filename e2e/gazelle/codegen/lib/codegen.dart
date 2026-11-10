import 'event.dart';
import 'profile.dart';
import 'user.dart';

/// A plain library beside the generated ones, at the pubspec's language
/// version like them.
String summary(User user, Profile profile, Event event) =>
    '${user.name} @${profile.handle} ${event.type}#${event.sequence}';
