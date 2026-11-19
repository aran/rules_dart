package dart

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/merger"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const program = "void main() {}\n"

// mergedBuild runs Gazelle over the files of directory rel, and merges what it
// generates into the BUILD file build, as `gazelle` does.
func mergedBuild(t *testing.T, rel string, files map[string]string, build string) map[string]*rule.Rule {
	t.Helper()
	tree := map[string]string{"pubspec.yaml": "name: app\n"}
	var names []string
	for name, content := range files {
		tree[rel+"/"+name] = content
		names = append(names, name)
	}
	sort.Strings(names)
	root := writeTree(t, tree)
	res := generate(t, &dartLang{}, root, rel, names, build)
	f, err := rule.LoadData(filepath.Join(root, rel, "BUILD.bazel"), rel, []byte(build))
	if err != nil {
		t.Fatal(err)
	}
	merger.MergeFile(f, res.Empty, res.Gen, merger.PreResolve, dartKinds(defaultBuilders()), nil)
	f.Sync()
	merged := map[string]*rule.Rule{}
	for _, r := range f.Rules {
		merged[r.Name()] = r
	}
	return merged
}

func TestHandSetMainSurvives(t *testing.T) {
	// Both orders of the two files, as Gazelle merges what it generates in
	// order, and a main in no file of the directory.
	for _, tt := range []struct {
		kind, rel, file, other string
	}{
		{"dart_binary", "bin", "foo.dart", "aaa.dart"},
		{"dart_binary", "bin", "foo.dart", "zzz.dart"},
		{"dart_binary", "bin", "foo.dart", "sub/other.dart"},
		{"dart_binary", "tool", "foo.dart", "aaa.dart"},
		{"dart_binary", "tool", "foo.dart", "zzz.dart"},
		{"dart_test", "test", "foo_test.dart", "aaa_test.dart"},
		{"dart_test", "test", "foo_test.dart", "zzz_test.dart"},
		{"dart_test", "test", "foo_test.dart", "sub/other_test.dart"},
	} {
		t.Run(tt.kind+" "+tt.rel+" "+tt.other, func(t *testing.T) {
			name := strings.TrimSuffix(tt.file, ".dart")
			build := fmt.Sprintf("%s(\n    name = %q,\n    main = %q,\n)\n", tt.kind, name, tt.other)
			files := map[string]string{tt.file: program}
			if !strings.Contains(tt.other, "/") {
				files[tt.other] = program
			}
			got := mergedBuild(t, tt.rel, files, build)
			r := got[name]
			if r == nil {
				t.Fatalf("%s was deleted: %v", name, got)
			}
			if m := r.AttrString("main"); m != tt.other {
				t.Errorf("main = %q, want the %q written by hand", m, tt.other)
			}
		})
	}
}

func TestStaleMainIsReplaced(t *testing.T) {
	part := map[string]string{
		"foo.dart":   "part 'piece.dart';\n\n" + program,
		"piece.dart": "part of 'foo.dart';\n",
	}
	t.Run("a binary of a part gives way to the file of its name", func(t *testing.T) {
		build := "dart_binary(\n    name = \"foo\",\n    main = \"piece.dart\",\n)\n"
		if r := mergedBuild(t, "bin", part, build)["foo"]; r == nil || r.AttrString("main") != "foo.dart" {
			t.Errorf("foo = %v, want a binary of foo.dart", r)
		}
	})
	t.Run("a binary of a part is deleted", func(t *testing.T) {
		build := "dart_binary(\n    name = \"piece\",\n    main = \"piece.dart\",\n)\n"
		if mergedBuild(t, "bin", part, build)["piece"] != nil {
			t.Errorf("the binary of a part was kept")
		}
	})
	t.Run("a test of a helper gives way to the file of its name", func(t *testing.T) {
		build := "dart_test(\n    name = \"foo_test\",\n    main = \"helper.dart\",\n)\n"
		got := mergedBuild(t, "test", map[string]string{
			"foo_test.dart": program,
			"helper.dart":   "int helper() => 1;\n",
		}, build)
		if r := got["foo_test"]; r == nil || r.AttrString("main") != "foo_test.dart" {
			t.Errorf("foo_test = %v, want a test of foo_test.dart", r)
		}
	})
}
