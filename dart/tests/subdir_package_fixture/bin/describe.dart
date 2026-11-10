import 'package:subdir_package_fixture/a.dart';

void main(List<String> args) =>
    print(describe(args.isEmpty ? ' x ' : args.first));
