package dart

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const greetingBuilder = "Greeting macro=@greeting_rules//ext:defs.bzl%greeting_codegen " +
	"shim=@greeting_rules//ext:shim produces=.greeting.g.part " +
	"runtime_dep=@pub_deps//:greeting key=greeting_builder"

func TestParseBuilder(t *testing.T) {
	b, err := parseBuilder(greetingBuilder)
	if err != nil {
		t.Fatal(err)
	}
	if b.Annotation != "Greeting" || b.ShimLabel != "@greeting_rules//ext:shim" ||
		b.Macro != "@greeting_rules//ext:defs.bzl%greeting_codegen" ||
		b.RuntimeDep != "@pub_deps//:greeting" || b.defaultRuntimeDep != b.RuntimeDep ||
		b.Key != "greeting_builder:greeting_builder" || !b.SharedPart ||
		len(b.Produces) != 1 || len(b.Consumes) != 1 {
		t.Errorf("parsed %+v", b)
	}
	lib, err := parseBuilder("Lib macro=//x:defs.bzl%lib_codegen shim=//x:shim produces=.a.dart,.b.dart runtime_dep=//x:lib")
	if err != nil {
		t.Fatal(err)
	}
	if lib.SharedPart || len(lib.Produces) != 2 || lib.Key != "" {
		t.Errorf("parsed %+v", lib)
	}
}

func TestParseBuilderRefuses(t *testing.T) {
	for value, want := range map[string]string{
		"":                                  "names no annotation",
		"macro=//x:d.bzl%m":                 "names no annotation",
		"A shim=//x:s produces=.a.dart":     "it states no `macro`, `runtime_dep`",
		"A macro=//x:d.bzl shim=//x:s":      "is not `<file>%<symbol>`",
		"A macro=//x:d.bzl%m macro=//y:e%n": "`macro` is stated twice",
		"A colour=red":                      "`colour` is not an attribute",
		"A produces=dart":                   "`dart` is not an extension",
		"A shim":                            "`shim` is not `<attribute>=<value>`",
	} {
		_, err := parseBuilder(value)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("parseBuilder(%q) = %v, want an error containing %q", value, err, want)
		}
	}
}

func rootWith(t *testing.T, content string) *config.Config {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "BUILD.bazel"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return &config.Config{RepoRoot: dir, ValidBuildFileNames: []string{"BUILD.bazel", "BUILD"}}
}

// The macro of a builder registered at the root is a rule kind Gazelle
// knows, loaded from the file the directive names.
func TestRootBuildersAreKinds(t *testing.T) {
	c := rootWith(t, "# gazelle:dart_builder "+greetingBuilder+"\n")
	d := &dartLang{}
	if err := d.CheckFlags(flag.NewFlagSet("gazelle", flag.ContinueOnError), c); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.Kinds()["greeting_codegen"]; !ok {
		t.Error("greeting_codegen is not a kind")
	}
	found := false
	for _, l := range d.Loads() {
		if l.Name == "@greeting_rules//ext:defs.bzl" && len(l.Symbols) == 1 && l.Symbols[0] == "greeting_codegen" {
			found = true
		}
	}
	if !found {
		t.Errorf("no load of greeting_codegen in %v", d.Loads())
	}
	if r := builderRegistryOf(c); len(r.lookup("Greeting")) != 1 {
		t.Error("the registry has no Greeting builder")
	}
}

func TestRootBuildersRefuseTakenNames(t *testing.T) {
	for content, want := range map[string]string{
		"# gazelle:dart_builder JsonSerializable macro=//x:d.bzl%j shim=//x:s produces=.j.dart runtime_dep=//x:l\n":                                                                     "`JsonSerializable` is a builder rules_dart ships",
		"# gazelle:dart_builder A macro=//x:d.bzl%dart_library shim=//x:s produces=.a.dart runtime_dep=//x:l\n":                                                                         "`dart_library` is a rule rules_dart ships",
		"# gazelle:dart_builder " + greetingBuilder + "\n# gazelle:dart_builder " + greetingBuilder + "\n":                                                                              "`Greeting` is registered by an earlier",
		"# gazelle:dart_builder " + greetingBuilder + "\n# gazelle:dart_builder B macro=@greeting_rules//ext:defs.bzl%greeting_codegen shim=//x:s produces=.b.dart runtime_dep=//x:l\n": "`greeting_codegen` is the macro of an earlier",
	} {
		_, err := rootBuilders(rootWith(t, content))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("rootBuilders(%q) = %v, want an error containing %q", content, err, want)
		}
	}
}

func TestNestedBuildersRefused(t *testing.T) {
	c := rootWith(t, "# gazelle:dart_builder "+greetingBuilder+"\n")
	f := loadBuildFile(t, c.RepoRoot)
	d := &dartLang{}
	d.refuseNestedBuilders("app", f)
	if len(d.errs.errors) != 1 {
		t.Fatalf("errors %v", d.errs.errors)
	}
	for m := range d.errs.errors {
		if !strings.Contains(m, "app/BUILD.bazel") || !strings.Contains(m, "root") {
			t.Errorf("error %q", m)
		}
	}
}

func loadBuildFile(t *testing.T, dir string) *rule.File {
	t.Helper()
	f, err := rule.LoadFile(filepath.Join(dir, "BUILD.bazel"), "app")
	if err != nil {
		t.Fatal(err)
	}
	return f
}
