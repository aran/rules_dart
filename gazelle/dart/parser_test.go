package dart

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTempDart(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "test.dart")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestParseDartFile(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    []DartImport
	}{
		{
			name:  "PlainPackageImport",
			input: `import 'package:foo/foo.dart';`,
			want: []DartImport{
				{URI: "package:foo/foo.dart", IsPackage: true, Package: "foo", Path: "foo.dart"},
			},
		},
		{
			name:  "RelativeImport",
			input: `import 'helper.dart';`,
			want: []DartImport{
				{URI: "helper.dart", IsRelative: true, Path: "helper.dart"},
			},
		},
		{
			name:  "DartSDKImport",
			input: `import 'dart:async';`,
			want: []DartImport{
				{URI: "dart:async", IsDartSDK: true},
			},
		},
		{
			name:  "SingleLineConditional",
			input: `import 'stub.dart' if (dart.library.io) 'io.dart';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io.dart", IsRelative: true, Path: "io.dart"},
			},
		},
		{
			name:  "SingleLineConditionalPackages",
			input: `import 'package:a/a.dart' if (dart.library.io) 'package:b/b.dart';`,
			want: []DartImport{
				{URI: "package:a/a.dart", IsPackage: true, Package: "a", Path: "a.dart"},
				{URI: "package:b/b.dart", IsPackage: true, Package: "b", Path: "b.dart"},
			},
		},
		{
			name: "MultilineConditional",
			input: `import 'stub.dart'
    if (dart.library.io) 'io_impl.dart'
    if (dart.library.js_interop) 'web_impl.dart';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
				{URI: "web_impl.dart", IsRelative: true, Path: "web_impl.dart"},
			},
		},
		{
			name: "MultilineConditionalExport",
			input: `export 'stub.dart'
    if (dart.library.io) 'io_impl.dart';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
			},
		},
		{
			name: "ConditionalWithTrailingModifier",
			input: `import 'stub.dart'
    if (dart.library.io) 'io_impl.dart'
    show PlatformClient;`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
			},
		},
		{
			name: "ConditionalThenPlainImport",
			input: `import 'stub.dart'
    if (dart.library.io) 'io_impl.dart';
import 'dart:async';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
				{URI: "dart:async", IsDartSDK: true},
			},
		},
		{
			name: "MixedImports",
			input: `import 'dart:io';
import 'package:foo/foo.dart';
import 'helper.dart';
import 'package:native_helpers/helpers.dart'
    if (dart.library.js_interop) 'package:web_helpers/helpers.dart';`,
			want: []DartImport{
				{URI: "dart:io", IsDartSDK: true},
				{URI: "package:foo/foo.dart", IsPackage: true, Package: "foo", Path: "foo.dart"},
				{URI: "helper.dart", IsRelative: true, Path: "helper.dart"},
				{URI: "package:native_helpers/helpers.dart", IsPackage: true, Package: "native_helpers", Path: "helpers.dart"},
				{URI: "package:web_helpers/helpers.dart", IsPackage: true, Package: "web_helpers", Path: "helpers.dart"},
			},
		},
		{
			name:  "EmptyFile",
			input: "",
			want:  nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeTempDart(t, tt.input)
			got, err := ParseDartFile(path)
			if err != nil {
				t.Fatalf("ParseDartFile() error = %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("ParseDartFile() returned %d imports, want %d\ngot:  %+v\nwant: %+v", len(got), len(tt.want), got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("import[%d] = %+v, want %+v", i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestParseDartAnnotations(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "PlainAnnotation",
			input: "@Foo\nclass A {}",
			want:  []string{"Foo"},
		},
		{
			name:  "AnnotationWithEmptyArgs",
			input: "@JsonSerializable()\nclass User {}",
			want:  []string{"JsonSerializable"},
		},
		{
			name:  "AnnotationWithNamedArg",
			input: "@JsonSerializable(createFactory: false)\nclass User {}",
			want:  []string{"JsonSerializable"},
		},
		{
			name:  "AnnotationWithDottedName",
			input: "@Foo.bar()\nclass A {}",
			want:  []string{"Foo.bar"},
		},
		{
			name:  "GenericAnnotation",
			input: "@Generated<String>()\nclass A {}",
			want:  []string{"Generated"},
		},
		{
			name: "MultipleAnnotationsOnSameClass",
			input: `@JsonSerializable()
@CopyWith()
class User {}`,
			want: []string{"JsonSerializable", "CopyWith"},
		},
		{
			name: "AnnotationOnMember",
			input: `class C {
  @override
  String foo() => '';
}`,
			want: []string{"override"},
		},
		{
			name:  "IgnoredInLineComment",
			input: "// @JsonSerializable() in comment\nclass A {}",
			want:  nil,
		},
		{
			name: "IgnoredInBlockComment",
			input: `/* @JsonSerializable() */
class A {}`,
			want: nil,
		},
		{
			name: "IgnoredInDocComment",
			input: `/// @JsonSerializable not a real annotation
class A {}`,
			want: nil,
		},
		{
			name:  "IgnoredInString",
			input: `final s = '@JsonSerializable should not match';`,
			want:  nil,
		},
		{
			name:  "IgnoredInRawString",
			input: `final s = r'@JsonSerializable raw';`,
			want:  nil,
		},
		{
			name: "IgnoredInTripleQuotedString",
			input: `final s = """
@JsonSerializable
""";`,
			want: nil,
		},
		{
			name: "Mixed",
			input: `// @Ignored
import 'foo.dart';

@freezed
class Event {}

/* @AlsoIgnored */
@JsonSerializable()
class User {}`,
			want: []string{"freezed", "JsonSerializable"},
		},
		{
			// Dart's lexer technically doesn't nest /* */ but our regex
			// shouldn't be confused by */ */ pairs either.
			name: "BlockCommentWithExtraStarSlash",
			input: `/* outer */ /* inner */
@Foo
class A {}`,
			want: []string{"Foo"},
		},
		{
			// Interpolated expressions are still inside a string literal,
			// so any @ inside should not match. (Conservative: parser
			// strips strings entirely, so even valid interpolation goes
			// quiet.)
			name:  "AtInsideStringInterpolation",
			input: `final s = 'hello \${a + b} @NotAnAnnotation';`,
			want:  nil,
		},
		{
			name: "TripleQuotedWithSingleQuoteInside",
			input: `final s = """
embedded "quotes" and 'single' don't break us.
@StillIgnored
""";
@RealAnnotation
class A {}`,
			want: []string{"RealAnnotation"},
		},
		{
			name:  "ConstAnnotation",
			input: `@SomeConst.namedConstructor() class A {}`,
			want:  []string{"SomeConst.namedConstructor"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeTempDart(t, tt.input)
			got, err := ParseDartAnnotations(path)
			if err != nil {
				t.Fatalf("ParseDartAnnotations() error = %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("ParseDartAnnotations() returned %d, want %d\ngot:  %v\nwant: %v", len(got), len(tt.want), got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("annotation[%d] = %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}

// TestParseDartAnnotationsReadError verifies that a missing file surfaces
// as a non-nil error rather than being conflated with "no annotations" —
// callers in generate.go rely on this distinction to log a warning.
func TestParseDartAnnotationsReadError(t *testing.T) {
	_, err := ParseDartAnnotations("/nonexistent/does-not-exist.dart")
	if err == nil {
		t.Fatal("ParseDartAnnotations on a missing path should return an error, got nil")
	}
}

func TestParseDartPartDirectives(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "SinglePart",
			input: "part 'user.g.dart';",
			want:  []string{"user.g.dart"},
		},
		{
			name:  "DoubleQuotedPart",
			input: `part "user.g.dart";`,
			want:  []string{"user.g.dart"},
		},
		{
			name: "MultipleParts",
			input: `part 'event.freezed.dart';
part 'event.g.dart';`,
			want: []string{"event.freezed.dart", "event.g.dart"},
		},
		{
			name:  "PartOfIsNotPart",
			input: "part of 'user.dart';",
			want:  nil,
		},
		{
			name:  "TrailingWhitespace",
			input: "part 'user.g.dart' ;  ",
			want:  []string{"user.g.dart"},
		},
		{
			name:  "Indented",
			input: "    part 'user.g.dart';",
			want:  []string{"user.g.dart"},
		},
		{
			name:  "IgnoredInComment",
			input: "// part 'fake.g.dart';",
			want:  nil,
		},
		{
			name: "Mixed",
			input: `import 'foo.dart';

part 'event.freezed.dart';
part of 'whatever.dart';
part 'event.g.dart';`,
			want: []string{"event.freezed.dart", "event.g.dart"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeTempDart(t, tt.input)
			got, err := ParseDartParts(path)
			if err != nil {
				t.Fatalf("ParseDartParts() error = %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("ParseDartParts() returned %d, want %d\ngot:  %v\nwant: %v", len(got), len(tt.want), got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("part[%d] = %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}
