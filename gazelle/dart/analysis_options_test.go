package dart

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

func TestIncludedPackages(t *testing.T) {
	tests := []struct {
		name string
		yaml string
		want []string
	}{
		{"scalar", "include: package:very_good_analysis/analysis_options.yaml\n", []string{"very_good_analysis"}},
		{"quoted with comment", "include: \"package:lints/core.yaml\" # base\n", []string{"lints"}},
		{"relative", "include: ../analysis_options.yaml\n", nil},
		{"flow list", "include: [package:a/x.yaml, ../y.yaml, 'package:b/z.yaml']\n", []string{"a", "b"}},
		{"block list", "include:\n  - package:a/x.yaml\n  # note\n  - package:a/y.yaml\n  - ../y.yaml\nlinter:\n  rules: []\n", []string{"a"}},
		{"nested include key ignored", "linter:\n  include: package:nope/x.yaml\n", nil},
		{"none", "linter:\n  rules:\n    - foo\n", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := includedPackages(tt.yaml); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}
}

// generate runs GenerateRules in dir (relative path rel) with the named files.
func generate(t *testing.T, d *dartLang, root, rel string, files []string, build string) language.GenerateResult {
	t.Helper()
	dir := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var f *rule.File
	if build != "" {
		var err error
		f, err = rule.LoadData(filepath.Join(dir, "BUILD.bazel"), rel, []byte(build))
		if err != nil {
			t.Fatal(err)
		}
	}
	return d.GenerateRules(language.GenerateArgs{
		Config:       &config.Config{RepoRoot: root, Exts: map[string]interface{}{}},
		Dir:          dir,
		Rel:          rel,
		File:         f,
		RegularFiles: files,
	})
}

func writeYaml(t *testing.T, root, rel, content string) {
	t.Helper()
	dir := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, analysisOptionsFile), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func findRule(res language.GenerateResult, name string) (*rule.Rule, int) {
	for i, r := range res.Gen {
		if r.Name() == name {
			return r, i
		}
	}
	return nil, -1
}

func TestOptionsRuleAndImports(t *testing.T) {
	root := t.TempDir()
	writeYaml(t, root, "tools", "include: package:very_good_analysis/analysis_options.yaml\n")
	res := generate(t, &dartLang{}, root, "tools", []string{analysisOptionsFile}, "")
	r, i := findRule(res, "analysis_options")
	if r == nil {
		t.Fatalf("no analysis_options rule: %v", res.Gen)
	}
	if r.Kind() != "dart_analysis_options" || r.AttrString("src") != analysisOptionsFile {
		t.Errorf("got %s src=%q", r.Kind(), r.AttrString("src"))
	}
	is, ok := res.Imports[i].(*importSet)
	if !ok || !is.packages["very_good_analysis"] || len(is.packages) != 1 {
		t.Errorf("imports = %#v, want very_good_analysis", res.Imports[i])
	}
}

func TestOptionsRuleNoIncludeHasNoImports(t *testing.T) {
	root := t.TempDir()
	writeYaml(t, root, "a", "linter:\n  rules: []\n")
	res := generate(t, &dartLang{}, root, "a", []string{analysisOptionsFile}, "")
	if len(res.Gen) != 1 || res.Imports[0] != nil {
		t.Errorf("gen=%v imports=%v", res.Gen, res.Imports)
	}
}

func TestOptionsRuleNaming(t *testing.T) {
	t.Run("reuses an existing rule for the yaml", func(t *testing.T) {
		root := t.TempDir()
		writeYaml(t, root, "a", "")
		build := "dart_analysis_options(name = \"lints\", src = \"analysis_options.yaml\")\n"
		res := generate(t, &dartLang{}, root, "a", []string{analysisOptionsFile}, build)
		if r, _ := findRule(res, "lints"); r == nil {
			t.Errorf("want existing name kept; gen=%v", res.Gen)
		}
	})
	t.Run("avoids another rule's name", func(t *testing.T) {
		root := t.TempDir()
		writeYaml(t, root, "a", "")
		build := "dart_library(name = \"analysis_options\", srcs = [\"x.dart\"])\n"
		res := generate(t, &dartLang{}, root, "a", []string{analysisOptionsFile}, build)
		if r, _ := findRule(res, analysisOptionsAltName); r == nil {
			t.Errorf("want %s; gen=%v", analysisOptionsAltName, res.Gen)
		}
	})
	t.Run("avoids a generated dart_library's name", func(t *testing.T) {
		root := t.TempDir()
		writeYaml(t, root, "analysis_options", "")
		if err := os.WriteFile(filepath.Join(root, "analysis_options", "a.dart"), []byte("class A {}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		res := generate(t, &dartLang{}, root, "analysis_options", []string{"a.dart", analysisOptionsFile}, "")
		lib, _ := findRule(res, "analysis_options")
		if lib == nil || lib.Kind() != "dart_library" {
			t.Fatalf("want dart_library analysis_options; gen=%v", res.Gen)
		}
		if r, _ := findRule(res, analysisOptionsAltName); r == nil {
			t.Errorf("want %s; gen=%v", analysisOptionsAltName, res.Gen)
		}
	})
}

func TestStaleOptionsRuleIsDeleted(t *testing.T) {
	root := t.TempDir()
	build := "dart_analysis_options(name = \"analysis_options\", src = \"analysis_options.yaml\")\n" +
		"dart_analysis_options(name = \"format_options\", src = \"format.yaml\")\n"
	res := generate(t, &dartLang{}, root, "a", nil, build)
	if len(res.Empty) != 1 || res.Empty[0].Name() != "analysis_options" {
		t.Errorf("empty = %v; want only analysis_options (format_options is the user's)", res.Empty)
	}
}

func options(t *testing.T, res language.GenerateResult) []string {
	t.Helper()
	r, _ := findRule(res, analysisConfigName)
	if r == nil {
		t.Fatalf("no config; gen=%v empty=%v", res.Gen, res.Empty)
	}
	return r.AttrStrings("options")
}

func TestConfigListsEveryVisitedDirSorted(t *testing.T) {
	root := t.TempDir()
	d := &dartLang{}
	writeYaml(t, root, "z", "")
	writeYaml(t, root, "a/b", "")
	writeYaml(t, root, "", "")
	generate(t, d, root, "z", []string{analysisOptionsFile}, "")
	generate(t, d, root, "a/b", []string{analysisOptionsFile}, "")
	generate(t, d, root, "a", nil, "")
	res := generate(t, d, root, "", []string{analysisOptionsFile}, "")
	want := []string{":analysis_options", "//a/b:analysis_options", "//z:analysis_options"}
	if got := options(t, res); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestConfigFullRunDropsRemovedDirs(t *testing.T) {
	root := t.TempDir()
	d := &dartLang{}
	writeYaml(t, root, "keep", "")
	generate(t, d, root, "keep", []string{analysisOptionsFile}, "")
	generate(t, d, root, "gone", nil, "") // visited, yaml deleted
	build := "dart_analysis_config(name = \"analysis_config\", options = [\"//keep:analysis_options\", \"//gone:analysis_options\"])\n"
	res := generate(t, d, root, "", nil, build)
	if got, want := options(t, res), []string{"//keep:analysis_options"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// A run that visits only the root (`gazelle -r=false .`) must not drop the
// entries of directories it did not visit.
func TestConfigRootOnlyRunKeepsUnvisitedEntries(t *testing.T) {
	root := t.TempDir()
	writeYaml(t, root, "sub", "")
	writeYaml(t, root, "renamed", "")
	build := "dart_analysis_config(name = \"analysis_config\", options = [\n" +
		"    \"//renamed:my_lints\",\n" +
		"    \"//sub:analysis_options\",\n" +
		"    \"//deleted:analysis_options\",\n" +
		"    \"@other//:analysis_options\",\n" +
		"])\n"
	res := generate(t, &dartLang{}, root, "", nil, build)
	want := []string{"//renamed:my_lints", "//sub:analysis_options"}
	if got := options(t, res); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// A visited directory decides its own entry, so a rename is picked up.
func TestConfigVisitedDirReplacesItsEntry(t *testing.T) {
	root := t.TempDir()
	d := &dartLang{}
	writeYaml(t, root, "sub", "")
	generate(t, d, root, "sub", []string{analysisOptionsFile},
		"dart_analysis_options(name = \"lints\", src = \"analysis_options.yaml\")\n")
	build := "dart_analysis_config(name = \"analysis_config\", options = [\"//sub:analysis_options\"])\n"
	res := generate(t, d, root, "", nil, build)
	if got, want := options(t, res), []string{"//sub:lints"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestConfigAbsentWhenNothingToList(t *testing.T) {
	root := t.TempDir()
	res := generate(t, &dartLang{}, root, "", nil, "")
	if r, _ := findRule(res, analysisConfigName); r != nil || len(res.Empty) != 0 {
		t.Errorf("gen=%v empty=%v", res.Gen, res.Empty)
	}
	build := "dart_analysis_config(name = \"analysis_config\", options = [\":analysis_options\"])\n"
	res = generate(t, &dartLang{}, root, "", nil, build)
	if len(res.Empty) != 0 {
		t.Errorf("config must never be deleted; empty=%v", res.Empty)
	}
	r, _ := findRule(res, analysisConfigName)
	if r == nil || len(r.AttrStrings("options")) != 0 {
		t.Errorf("want config kept with empty options; gen=%v", res.Gen)
	}
	if _, ok := dartKinds["dart_analysis_config"]; !ok || len(dartKinds["dart_analysis_config"].NonEmptyAttrs) != 0 {
		t.Errorf("config kind must have no NonEmptyAttrs, or the merger deletes it when empty")
	}
}

func TestConfigNameHeldByAnotherKindIsLeftAlone(t *testing.T) {
	root := t.TempDir()
	writeYaml(t, root, "", "")
	res := generate(t, &dartLang{}, root, "", []string{analysisOptionsFile},
		"filegroup(name = \"analysis_config\")\n")
	if r, _ := findRule(res, analysisConfigName); r != nil {
		t.Errorf("must not claim a name held by a filegroup")
	}
}
