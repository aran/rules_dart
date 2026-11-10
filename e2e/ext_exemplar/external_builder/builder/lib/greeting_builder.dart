import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

/// A SharedPartBuilder writing `greet<Class>()` for each `@Greeting` class.
Builder greetingBuilder(BuilderOptions options) =>
    SharedPartBuilder([_GreetingGenerator()], 'greeting');

class _GreetingGenerator extends GeneratorForAnnotation<Object> {
  @override
  TypeChecker get typeChecker =>
      const TypeChecker.fromUrl('package:greeting/greeting.dart#Greeting');

  @override
  String generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    final name = element.name;
    final salutation = annotation.read('salutation').stringValue;
    return "String greet$name() => '$salutation, $name';";
  }
}
