package dart

import (
	"reflect"
	"sort"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// cycleErrors is what check reports for packages (name to root and the
// packages it imports), under the directives decls, each of whose
// directories was written.
func cycleErrors(packages map[string][2][]string, decls ...*cycleDecl) []string {
	s := &cycleState{written: map[*cycleDecl]bool{}}
	for _, decl := range decls {
		s.declared(decl)
		s.written[decl] = true
	}
	for name, p := range packages {
		cp := &cyclePackage{root: p[0][0], imports: p[1]}
		for _, decl := range decls {
			if contains(decl.Packages, name) && (decl.Dir == "" || cp.root == decl.Dir || len(cp.root) > len(decl.Dir) && cp.root[:len(decl.Dir)+1] == decl.Dir+"/") {
				cp.decl = decl
			}
		}
		s.record(name, cp)
	}
	var errs generationErrors
	s.check(&errs)
	var out []string
	for e := range errs.errors {
		out = append(out, e)
	}
	sort.Strings(out)
	return out
}

func pkg(root string, imports ...string) [2][]string {
	return [2][]string{{root}, imports}
}

func TestCycleCheck(t *testing.T) {
	for _, tt := range []struct {
		name     string
		packages map[string][2][]string
		decls    []*cycleDecl
		want     []string
	}{
		{
			name: "no cycle",
			packages: map[string][2][]string{
				"ping": pkg("pp/ping", "pong"),
				"pong": pkg("pp/pong"),
			},
		},
		{
			name: "undeclared cycle",
			packages: map[string][2][]string{
				"ping": pkg("pp/ping", "pong", "collection"),
				"pong": pkg("pp/pong", "ping"),
			},
			want: []string{"dart: packages `ping` and `pong` depend on each other: ping -> pong -> ping. " +
				"Bazel builds no cycle of targets, so packages that import each other are built as one " +
				"target, where a directive declares them. Add it to the BUILD file of pp, or of a " +
				"directory above it:\n\n    # gazelle:dart_cycle ping pong"},
		},
		{
			name: "declared cycle",
			packages: map[string][2][]string{
				"ping": pkg("pp/ping", "pong"),
				"pong": pkg("pp/pong", "ping"),
			},
			decls: []*cycleDecl{{Packages: []string{"ping", "pong"}, Dir: "pp", File: "pp/BUILD.bazel"}},
		},
		{
			name: "stale directive",
			packages: map[string][2][]string{
				"ping": pkg("pp/ping", "pong"),
				"pong": pkg("pp/pong"),
			},
			decls: []*cycleDecl{{Packages: []string{"ping", "pong"}, Dir: "pp", File: "pp/BUILD.bazel"}},
			want: []string{"dart: pp/BUILD.bazel: `# gazelle:dart_cycle ping pong` is not a dependency " +
				"cycle: `ping` is in no cycle. Remove it from the directive, or remove the directive."},
		},
		{
			name: "directive naming part of a cycle",
			packages: map[string][2][]string{
				"a": pkg("a", "b"),
				"b": pkg("b", "c"),
				"c": pkg("c", "a"),
			},
			decls: []*cycleDecl{{Packages: []string{"a", "b"}, Dir: "", File: "BUILD.bazel"}},
			want: []string{"dart: BUILD.bazel: `# gazelle:dart_cycle a b` is not a dependency cycle: " +
				"`a` is in the cycle of `a`, `b` and `c` (a -> b -> c -> a). Declare that cycle instead, " +
				"with every package in it:\n\n    # gazelle:dart_cycle a b c"},
		},
		{
			name: "directive below a package",
			packages: map[string][2][]string{
				"ping": pkg("ping", "pong"),
				"pong": pkg("pp/pong", "ping"),
			},
			decls: []*cycleDecl{{Packages: []string{"ping", "pong"}, Dir: "pp", File: "pp/BUILD.bazel"}},
			want: []string{"dart: pp/BUILD.bazel: `# gazelle:dart_cycle ping pong` names `ping`, rooted " +
				"at ping, which is not under pp; state the directive in a BUILD file above every package it names"},
		},
		{
			name: "directive naming no package",
			packages: map[string][2][]string{
				"ping": pkg("pp/ping"),
			},
			decls: []*cycleDecl{{Packages: []string{"ping", "pung"}, Dir: "pp", File: "pp/BUILD.bazel"}},
			want: []string{"dart: pp/BUILD.bazel: `# gazelle:dart_cycle ping pung` names `pung`, a " +
				"package Gazelle found no lib/ of under pp"},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := cycleErrors(tt.packages, tt.decls...); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("got  %q\nwant %q", got, tt.want)
			}
		})
	}
}

func TestConfigureCyclesRefusesMalformed(t *testing.T) {
	f, err := rule.LoadData("pp/BUILD.bazel", "pp", []byte(
		"# gazelle:dart_cycle ping pong\n# gazelle:dart_cycle pong peng\n# gazelle:dart_cycle solo\n"))
	if err != nil {
		t.Fatal(err)
	}
	c := config.New()
	d := &dartLang{}
	d.configureCycles(c, "pp", f)
	var got []string
	for e := range d.errs.errors {
		got = append(got, e)
	}
	sort.Strings(got)
	want := []string{
		"dart: pp/BUILD.bazel: `# gazelle:dart_cycle peng pong` names `pong`, which `# gazelle:dart_cycle ping pong` in pp/BUILD.bazel names too; a package is in one cycle, so declare it once, with every package in it",
		"dart: pp/BUILD.bazel: `# gazelle:dart_cycle solo` names fewer than two packages; a cycle is of several",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got  %q\nwant %q", got, want)
	}
	if n := len(cyclesOf(c)); n != 3 {
		t.Errorf("%d directives in force, want 3", n)
	}
}

func TestCommonDir(t *testing.T) {
	for _, tt := range []struct {
		dirs []string
		want string
	}{
		{[]string{"pp/ping", "pp/pong"}, "pp"},
		{[]string{"a/b/c", "a/b"}, "a/b"},
		{[]string{"ping", "pong"}, ""},
		{[]string{"", "pong"}, ""},
	} {
		if got := commonDir(tt.dirs); got != tt.want {
			t.Errorf("commonDir(%q) = %q, want %q", tt.dirs, got, tt.want)
		}
	}
}
