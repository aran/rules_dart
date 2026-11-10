package dart

import (
	"reflect"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/rule"
)

func TestTestTagsFromSource(t *testing.T) {
	tests := []struct {
		name     string
		src      string
		want     []string
		problems []string // substrings, one per expected problem
	}{
		{
			name: "before an unnamed library directive",
			src:  "@Tags(['slow', 'integration'])\nlibrary;\n\nimport 'package:test/test.dart';\n",
			want: []string{"integration", "slow"},
		},
		{
			name: "before a named library directive",
			src:  "@Tags(['slow'])\nlibrary foo_test;\n",
			want: []string{"slow"},
		},
		{
			name: "before the first import, no library directive",
			src:  "@Tags([\"browser\"])\n\nimport 'package:test/test.dart';\n",
			want: []string{"browser"},
		},
		{
			name: "import-prefixed",
			src:  "@t.Tags(['db'])\nlibrary;\n\nimport 'package:test/test.dart' as t;\n",
			want: []string{"db"},
		},
		{
			name: "const, typed, trailing comma, comments, raw and adjacent strings",
			src: "// Copyright\n// @dart=3.10\n/* x */ @Tags(const <String>[\n" +
				"  'a', // first\n  r'b-c',\n  'd' \"e\",\n])\n@TestOn('vm')\nlibrary;\n",
			want: []string{"a", "b-c", "de"},
		},
		{
			name: "duplicates collapse",
			src:  "@Tags(['x', 'x'])\nlibrary;\n",
			want: []string{"x"},
		},
		{
			name: "after a script line",
			src:  "#!/usr/bin/env dart\n@Tags(['x'])\nlibrary;\n",
			want: []string{"x"},
		},
		{
			name: "on a declaration, not a directive: package:test ignores it",
			src:  "@Tags(['x'])\nvoid main() {}\n",
		},
		{
			name: "dotted name whose head is not an import prefix",
			src:  "@Foo.Tags(['x'])\nlibrary;\n",
		},
		{
			name: "case-level tags are not suite tags",
			src:  "import 'package:test/test.dart';\nvoid main() { test('a', () {}, tags: ['x']); }\n",
		},
		{
			name: "inside a comment or string",
			src:  "// @Tags(['x'])\nimport 'a.dart';\nvar s = \"@Tags(['y'])\";\n",
		},
		{
			name:     "const variable",
			src:      "@Tags(slowTags)\nlibrary;\nconst slowTags = ['slow'];\n",
			problems: []string{"not a list of string literals"},
		},
		{
			name:     "interpolation",
			src:      "@Tags(['slow', '$kind'])\nlibrary;\n",
			problems: []string{"not a list of string literals"},
		},
		{
			name:     "no arguments",
			src:      "@Tags\nlibrary;\n",
			problems: []string{"not a list of string literals"},
		},
		{
			name:     "Bazel-reserved names are refused, the rest kept",
			src:      "@Tags(['manual', 'exclusive', 'requires-network', 'no-sandbox', 'local', 'slow'])\nlibrary;\n",
			want:     []string{"slow"},
			problems: []string{`"manual"`, `"exclusive"`, `"requires-network"`, `"no-sandbox"`, `"local"`},
		},
		{
			name:     "invalid package:test tag name",
			src:      "@Tags(['has space', 'ok'])\nlibrary;\n",
			want:     []string{"ok"},
			problems: []string{`"has space"`},
		},
		{
			name:     "two @Tags",
			src:      "@Tags(['a'])\n@Tags(['b'])\nlibrary;\n",
			problems: []string{"more than one"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, problems := testTagsFromSource(tc.src)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("tags = %q, want %q", got, tc.want)
			}
			if len(problems) != len(tc.problems) {
				t.Fatalf("problems = %q, want %d matching %q", problems, len(tc.problems), tc.problems)
			}
			for i, p := range tc.problems {
				if !strings.Contains(problems[i], p) {
					t.Errorf("problem %d = %q, want it to mention %q", i, problems[i], p)
				}
			}
		})
	}
}

func TestDroppedHandTags(t *testing.T) {
	build := `
dart_test(
    name = "plain",
    main = "plain.dart",
    tags = ["slow", "manual", "exclusive",  # keep
    ],
)

dart_test(
    name = "attr_kept",
    main = "attr_kept.dart",
    tags = ["manual"],  # keep
)

# keep
dart_test(
    name = "rule_kept",
    main = "rule_kept.dart",
    tags = ["manual"],
)

dart_test(
    name = "untagged",
    main = "untagged.dart",
)
`
	f, err := rule.LoadData("BUILD.bazel", "", []byte(build))
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]*rule.Rule{}
	for _, r := range f.Rules {
		byName[r.Name()] = r
	}
	tests := []struct {
		rule      string
		generated []string
		want      []string
	}{
		{"plain", []string{"slow"}, []string{"manual"}},
		{"plain", nil, []string{"slow", "manual"}},
		{"attr_kept", nil, nil},
		{"rule_kept", nil, nil},
		{"untagged", []string{"slow"}, nil},
	}
	for _, tc := range tests {
		got := droppedHandTags(byName[tc.rule], tc.generated)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s with %q: dropped = %q, want %q", tc.rule, tc.generated, got, tc.want)
		}
	}
}

func TestBazelReservedTag(t *testing.T) {
	for _, tag := range []string{"manual", "exclusive", "exclusive-if-local", "external",
		"local", "no-remote", "no-cache", "requires-network", "supports-workers",
		"block-network", "disable-foo"} {
		if !bazelReservedTag(tag) {
			t.Errorf("bazelReservedTag(%q) = false", tag)
		}
	}
	for _, tag := range []string{"slow", "integration", "browser", "nope", "local-db", "manually"} {
		if bazelReservedTag(tag) {
			t.Errorf("bazelReservedTag(%q) = true", tag)
		}
	}
}
