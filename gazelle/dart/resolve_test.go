package dart

import (
	"flag"
	"slices"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// resolveIn indexes the dart_library `lib` (package_name `app`) at //lib,
// then resolves the imported packages of `r`, declared in Bazel package
// `pkg`, and returns its deps.
func resolveIn(t *testing.T, r *rule.Rule, pkg string, imported ...string) []string {
	t.Helper()
	c := config.New()
	c.Exts["dart_pub_deps_repo"] = "pub_deps"
	rc := &resolve.Configurer{}
	rc.RegisterFlags(flag.NewFlagSet("test", flag.ContinueOnError), "update", c)
	if err := rc.CheckFlags(nil, c); err != nil {
		t.Fatal(err)
	}
	rc.Configure(c, "", nil)

	lang := NewLanguage()
	ix := resolve.NewRuleIndex(func(*rule.Rule, string) resolve.Resolver { return lang })
	f := rule.EmptyFile("lib/BUILD.bazel", "lib")
	lib := rule.NewRule("dart_library", "lib")
	lib.SetAttr("package_name", "app")
	lib.Insert(f)
	ix.AddRule(c, lib, f)
	ix.Finish()

	is := &importSet{packages: map[string]bool{}}
	for _, p := range imported {
		is.packages[p] = true
	}
	lang.(*dartLang).Resolve(c, ix, nil, r, is, label.New("", pkg, r.Name()))
	return r.AttrStrings("deps")
}

func TestResolveExecutableNamedForPackageDependsOnIt(t *testing.T) {
	for _, kind := range []string{"dart_binary", "dart_test"} {
		got := resolveIn(t, rule.NewRule(kind, "app"), "bin", "app", "path")
		want := []string{"//lib", "@pub_deps//:path"}
		if !slices.Equal(got, want) {
			t.Errorf("%s app: deps %v, want %v", kind, got, want)
		}
	}
}

func TestResolveLibraryDoesNotDependOnPackageItProvides(t *testing.T) {
	for _, tt := range []struct {
		name, packageName string
	}{
		{"app", ""},
		{"lib", "app"},
	} {
		r := rule.NewRule("dart_library", tt.name)
		if tt.packageName != "" {
			r.SetAttr("package_name", tt.packageName)
		}
		if got := resolveIn(t, r, "lib", "app"); len(got) != 0 {
			t.Errorf("dart_library %q (package_name %q): deps %v, want none", tt.name, tt.packageName, got)
		}
	}
}
