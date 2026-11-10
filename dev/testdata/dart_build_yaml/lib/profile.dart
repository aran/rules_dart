import 'package:copy_with_extension/copy_with_extension.dart';

part 'profile.g.dart';

@CopyWith()
class Profile {
  Profile({required this.handle});

  final String handle;
}
