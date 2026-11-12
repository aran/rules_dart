package dart

import (
	"fmt"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Packages of the repository that import each other are built as one
// `dart_package_cycle`, since Bazel builds no cycle of targets, and only where
// a `# gazelle:dart_cycle a b` directive declares them. The directive holds
// in its directory and below, so it sits in a BUILD file above every package
// it names. Each package's root gets a `dart_package_member` in place of its
// `dart_library`, and an `alias` named like the library, pointing at the
// cycle. The cycle itself is written in the directive's directory and is what
// imports of the packages resolve to.
//
// Gazelle writes a directory after those below it, so the directive's
// directory sees every member's imports. Whether the packages are a cycle,
// and whether any cycle is undeclared, is known once every directory is
// generated: `DoneGeneratingRules` checks, and fails the run before anything
// is written (agreement.go).

// keyCycle is the directive declaring a cycle: the names of its packages.
const keyCycle = "dart_cycle"

// extKeyCycles holds the cycle directives in force in a directory.
const extKeyCycles = "dart_cycles"

// cycleDecl is one `# gazelle:dart_cycle` directive.
type cycleDecl struct {
	Packages []string // sorted
	Dir      string   // the directory whose BUILD file states it
	File     string   // that BUILD file, repo-relative
}

// name is the name of the cycle's `dart_package_cycle`.
func (d *cycleDecl) name() string { return strings.Join(d.Packages, "_") }

func (d *cycleDecl) label() label.Label { return label.New("", d.Dir, d.name()) }

func (d *cycleDecl) directive() string { return cycleDirective(d.Packages) }

func cycleDirective(packages []string) string {
	return "# gazelle:" + keyCycle + " " + strings.Join(packages, " ")
}

// cyclesOf is the cycle directives in force under c.
func cyclesOf(c *config.Config) []*cycleDecl {
	decls, _ := c.Exts[extKeyCycles].([]*cycleDecl)
	return decls
}

// cycleOf is the directive in force under c naming pkg, or nil.
func cycleOf(c *config.Config, pkg string) *cycleDecl {
	for _, d := range cyclesOf(c) {
		for _, p := range d.Packages {
			if p == pkg {
				return d
			}
		}
	}
	return nil
}

// configureCycles adds the cycle directives of f, the BUILD file of rel, to
// those in force above it, and records an error for one that names fewer
// than two packages, one twice, or one another directive in force names too.
func (d *dartLang) configureCycles(c *config.Config, rel string, f *rule.File) {
	if f == nil {
		return
	}
	var added []*cycleDecl
	for _, dir := range f.Directives {
		if dir.Key != keyCycle {
			continue
		}
		file := path.Join(rel, filepath.Base(f.Path))
		names := strings.Fields(dir.Value)
		decl := &cycleDecl{Packages: sortedCopy(names), Dir: rel, File: file}
		distinct := map[string]bool{}
		for _, n := range names {
			distinct[n] = true
		}
		switch {
		case len(distinct) != len(names):
			d.errs.add(fmt.Sprintf("dart: %s: `%s` names a package more than once", file, decl.directive()))
		case len(names) < 2:
			d.errs.add(fmt.Sprintf("dart: %s: `%s` names fewer than two packages; a cycle is of several", file, decl.directive()))
		}
		for _, other := range append(append([]*cycleDecl(nil), cyclesOf(c)...), added...) {
			for _, n := range decl.Packages {
				if distinct[n] && contains(other.Packages, n) {
					d.errs.add(fmt.Sprintf(
						"dart: %s: `%s` names `%s`, which `%s` in %s names too; a package is in one cycle, so declare it once, with every package in it",
						file, decl.directive(), n, other.directive(), other.File))
				}
			}
		}
		added = append(added, decl)
		d.cycles.declared(decl)
	}
	if len(added) > 0 {
		c.Exts[extKeyCycles] = append(append([]*cycleDecl(nil), cyclesOf(c)...), added...)
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// cycleState is what generating every directory learns of the packages'
// imports, for the cycles' rules and the check of their directives.
type cycleState struct {
	mu       sync.Mutex
	packages map[string]*cyclePackage
	decls    map[string]*cycleDecl // by File and directive
	written  map[*cycleDecl]bool   // the directives whose cycle was written
}

// cyclePackage is a package Gazelle wrote the library of, or the member of.
type cyclePackage struct {
	root    string
	imports []string // the packages its lib/ imports, itself left out
	// Set when it is built as a member of decl.
	decl   *cycleDecl
	member label.Label
	is     *importSet
	specs  []resolve.ImportSpec
	// What its codegen targets generate, which the cycle holds.
	generated []label.Label
}

func (s *cycleState) declared(decl *cycleDecl) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.decls == nil {
		s.decls = map[string]*cycleDecl{}
	}
	s.decls[decl.File+" "+decl.directive()] = decl
}

func (s *cycleState) record(name string, p *cyclePackage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.packages == nil {
		s.packages = map[string]*cyclePackage{}
	}
	s.packages[name] = p
}

func (s *cycleState) lookup(name string) *cyclePackage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.packages[name]
}

// cycleSpecs is what the `dart_package_cycle` of decl provides: every
// member's package and files.
func (s *cycleState) cycleSpecs(decl *cycleDecl) []resolve.ImportSpec {
	var specs []resolve.ImportSpec
	for _, p := range decl.Packages {
		if m := s.lookup(p); m != nil && m.decl == decl {
			specs = append(specs, m.specs...)
		}
	}
	return specs
}

// declAt is the directive in force at rel naming the cycle named name.
func declAt(c *config.Config, rel, name string) *cycleDecl {
	for _, d := range cyclesOf(c) {
		if d.Dir == rel && d.name() == name {
			return d
		}
	}
	return nil
}

// packageImports is the packages is names, pkg left out.
func packageImports(is *importSet, pkg string) []string {
	var out []string
	for _, p := range is.SortedPackages() {
		if p != pkg {
			out = append(out, p)
		}
	}
	return out
}

// cycleMemberRules records the library lib, of the package rooted at root,
// and its imports, and, when a directive names its package, makes it the
// package's member, with an alias in its name for the cycle. It returns the
// rules to write in lib's place, their imports, and the rules to delete:
// the library a member replaces, or the member and alias a library does.
//
// genSrcs are the labels in lib's srcs of what its codegen rules, codegen,
// generate, and codegenImports those rules' imports. A member holds only its
// package's own sources: each generator of the cycle reads every member, so
// the cycle holds what they generate.
func (d *dartLang) cycleMemberRules(args language.GenerateArgs, root string, lib *rule.Rule, is *importSet, genSrcs []string, codegen []*rule.Rule, codegenImports []interface{}) ([]*rule.Rule, []interface{}, []*rule.Rule) {
	pkg := lib.Name()
	p := &cyclePackage{root: root, imports: packageImports(is, pkg)}
	decl := cycleOf(args.Config, pkg)
	memberName := pkg + "_member"
	if decl == nil {
		d.cycles.record(pkg, p)
		var empty []*rule.Rule
		if args.File != nil {
			for _, r := range args.File.Rules {
				if r.Kind() == "dart_package_member" && r.Name() == memberName && !r.ShouldKeep() {
					empty = append(empty, rule.NewRule("dart_package_member", memberName))
					for _, a := range args.File.Rules {
						if a.Kind() == "alias" && a.Name() == pkg && !a.ShouldKeep() {
							empty = append(empty, rule.NewRule("alias", pkg))
						}
					}
				}
			}
		}
		return []*rule.Rule{lib}, []interface{}{is}, empty
	}
	p.decl = decl
	p.member = label.New("", root, memberName)
	p.is = is
	p.specs = d.importSpecs(args.Config, lib, root)
	d.cycles.record(pkg, p)

	generated := map[string]bool{}
	for _, g := range genSrcs {
		generated[g] = true
		p.generated = append(p.generated, label.New("", root, strings.TrimPrefix(g, ":")))
	}
	for _, c := range codegenImports {
		if cis, ok := c.(*importSet); ok && cis != nil {
			cis.cycle = decl
		}
	}
	for _, r := range codegen {
		if generated[":"+r.Name()] {
			r.SetAttr("visibility", []string{label.New("", decl.Dir, "__pkg__").String()})
		}
	}

	member := rule.NewRule("dart_package_member", memberName)
	var srcs []string
	for _, s := range lib.AttrStrings("srcs") {
		if !generated[s] {
			srcs = append(srcs, s)
		}
	}
	member.SetAttr("srcs", srcs)
	if v := lib.Attr("package"); v != nil {
		member.SetAttr("package", v)
	}
	// The cycle builds it, and the generators of every member read it.
	member.SetAttr("visibility", []string{label.New("", decl.Dir, "__subpackages__").String()})
	alias := rule.NewRule("alias", pkg)
	alias.SetAttr("actual", decl.label().Rel("", root).String())
	alias.SetAttr("visibility", []string{"//visibility:public"})
	var empty []*rule.Rule
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "dart_library" && r.Name() == pkg && !r.ShouldKeep() {
				empty = append(empty, rule.NewRule("dart_library", pkg))
			}
		}
	}
	return []*rule.Rule{member, alias}, []interface{}{nil, nil}, empty
}

// cycleRules is the `dart_package_cycle` of each directive the BUILD file of
// args.Rel states, over the members written below it, and what they import;
// and a marker deleting each cycle there no directive states any more.
func (d *dartLang) cycleRules(args language.GenerateArgs) ([]*rule.Rule, []interface{}, []*rule.Rule) {
	var gen []*rule.Rule
	var imports []interface{}
	names := map[string]bool{}
	for _, decl := range cyclesOf(args.Config) {
		if decl.Dir != args.Rel {
			continue
		}
		d.cycles.mu.Lock()
		if d.cycles.written == nil {
			d.cycles.written = map[*cycleDecl]bool{}
		}
		d.cycles.written[decl] = true
		d.cycles.mu.Unlock()
		is := &importSet{packages: map[string]bool{}, uris: map[string]map[string]bool{}}
		var members, generated []string
		for _, p := range decl.Packages {
			m := d.cycles.lookup(p)
			if m == nil || m.decl != decl {
				continue
			}
			members = append(members, m.member.Rel("", args.Rel).String())
			for _, g := range m.generated {
				generated = append(generated, g.Rel("", args.Rel).String())
			}
			for pkg := range m.is.packages {
				is.packages[pkg] = true
			}
			for pkg, uris := range m.is.uris {
				if is.uris[pkg] == nil {
					is.uris[pkg] = map[string]bool{}
				}
				for u := range uris {
					is.uris[pkg][u] = true
				}
			}
			is.labels = append(is.labels, m.is.labels...)
		}
		if len(members) == 0 {
			continue
		}
		r := rule.NewRule("dart_package_cycle", decl.name())
		sort.Strings(members)
		r.SetAttr("members", members)
		if len(generated) > 0 {
			sort.Strings(generated)
			r.SetAttr("srcs", generated)
		}
		r.SetAttr("visibility", []string{"//visibility:public"})
		gen = append(gen, r)
		imports = append(imports, is)
		names[r.Name()] = true
	}
	var empty []*rule.Rule
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "dart_package_cycle" && !names[r.Name()] && !r.ShouldKeep() {
				empty = append(empty, rule.NewRule("dart_package_cycle", r.Name()))
			}
		}
	}
	return gen, imports, empty
}

// members is the labels of the members of decl and, merged, what they import
// from outside it.
func (s *cycleState) members(decl *cycleDecl) ([]label.Label, *importSet) {
	is := &importSet{packages: map[string]bool{}, uris: map[string]map[string]bool{}}
	in := map[string]bool{}
	for _, p := range decl.Packages {
		in[p] = true
	}
	var labels []label.Label
	for _, p := range decl.Packages {
		m := s.lookup(p)
		if m == nil || m.decl != decl {
			continue
		}
		labels = append(labels, m.member)
		for pkg := range m.is.packages {
			if !in[pkg] {
				is.packages[pkg] = true
			}
		}
		for pkg, uris := range m.is.uris {
			if in[pkg] {
				continue
			}
			if is.uris[pkg] == nil {
				is.uris[pkg] = map[string]bool{}
			}
			for u := range uris {
				is.uris[pkg][u] = true
			}
		}
		is.labels = append(is.labels, m.is.labels...)
	}
	return labels, is
}

// check records an error for each cycle of packages no directive declares,
// and for each directive whose directory was written that is not exactly a
// cycle.
func (s *cycleState) check(errs *generationErrors) {
	s.mu.Lock()
	defer s.mu.Unlock()
	graph := map[string][]string{}
	var names []string
	for name, p := range s.packages {
		names = append(names, name)
		for _, dep := range p.imports {
			if _, ok := s.packages[dep]; ok {
				graph[name] = append(graph[name], dep)
			}
		}
	}
	sort.Strings(names)
	componentOf := map[string][]string{}
	for _, c := range stronglyConnected(names, graph) {
		for _, n := range c {
			componentOf[n] = c
		}
	}

	// The directives, in a stable order.
	var keys []string
	for k := range s.decls {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	covered := map[string]bool{}
	for _, k := range keys {
		decl := s.decls[k]
		for _, p := range decl.Packages {
			covered[p] = true
		}
		if !s.written[decl] {
			continue
		}
		if msg := s.declError(decl, graph, componentOf); msg != "" {
			errs.add(msg)
		}
	}

	seen := map[string]bool{}
	for _, n := range names {
		c := componentOf[n]
		if len(c) < 2 || seen[c[0]] {
			continue
		}
		seen[c[0]] = true
		declared := false
		for _, p := range c {
			declared = declared || covered[p]
		}
		if declared {
			// A directive naming some of them is not exactly this
			// cycle, and its own error says so.
			continue
		}
		var roots []string
		for _, p := range c {
			roots = append(roots, s.packages[p].root)
		}
		errs.add(fmt.Sprintf(
			"dart: packages %s depend on each other: %s. Bazel builds no "+
				"cycle of targets, so packages that import each other are built "+
				"as one target, where a directive declares them. Add it to the "+
				"BUILD file of %s, or of a directory above it:\n\n    %s",
			backticked(c), cyclePath(graph, c[0], c), dirName(commonDir(roots)), cycleDirective(c)))
	}
}

// declError is what is wrong with decl, a directive whose directory was
// written, or "".
func (s *cycleState) declError(decl *cycleDecl, graph map[string][]string, componentOf map[string][]string) string {
	where := fmt.Sprintf("dart: %s: `%s`", decl.File, decl.directive())
	for _, p := range decl.Packages {
		m, ok := s.packages[p]
		switch {
		case !ok:
			return fmt.Sprintf("%s names `%s`, a package Gazelle found no lib/ of under %s", where, p, dirName(decl.Dir))
		case m.decl != decl:
			return fmt.Sprintf("%s names `%s`, rooted at %s, which is not under %s; state the directive in a BUILD file above every package it names", where, p, dirName(m.root), dirName(decl.Dir))
		}
	}
	for _, p := range decl.Packages {
		c := componentOf[p]
		if strings.Join(c, " ") == strings.Join(decl.Packages, " ") {
			continue
		}
		if len(c) == 1 {
			return fmt.Sprintf("%s is not a dependency cycle: `%s` is in no cycle. Remove it from the directive, or remove the directive.", where, p)
		}
		return fmt.Sprintf("%s is not a dependency cycle: `%s` is in the cycle of %s (%s). Declare that cycle instead, with every package in it:\n\n    %s",
			where, p, backticked(c), cyclePath(graph, p, c), cycleDirective(c))
	}
	return ""
}

// stronglyConnected is the strongly connected components of graph over
// nodes, each sorted.
func stronglyConnected(nodes []string, graph map[string][]string) [][]string {
	index := map[string]int{}
	low := map[string]int{}
	onStack := map[string]bool{}
	var stack []string
	var out [][]string
	var visit func(v string)
	visit = func(v string) {
		index[v] = len(index)
		low[v] = index[v]
		stack = append(stack, v)
		onStack[v] = true
		for _, w := range sortedCopy(graph[v]) {
			if _, ok := index[w]; !ok {
				visit(w)
				low[v] = min(low[v], low[w])
			} else if onStack[w] {
				low[v] = min(low[v], index[w])
			}
		}
		if low[v] == index[v] {
			var c []string
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[w] = false
				c = append(c, w)
				if w == v {
					break
				}
			}
			sort.Strings(c)
			out = append(out, c)
		}
	}
	for _, n := range nodes {
		if _, ok := index[n]; !ok {
			visit(n)
		}
	}
	return out
}

// cyclePath is a shortest way from start back to itself through members, as
// `a -> b -> a`.
func cyclePath(graph map[string][]string, start string, members []string) string {
	inside := map[string]bool{}
	for _, m := range members {
		inside[m] = true
	}
	cameFrom := map[string]string{}
	queue := []string{start}
	for len(queue) > 0 {
		if _, ok := cameFrom[start]; ok {
			break
		}
		var next []string
		for _, node := range queue {
			for _, dep := range sortedCopy(graph[node]) {
				if _, ok := cameFrom[dep]; inside[dep] && !ok {
					cameFrom[dep] = node
					next = append(next, dep)
				}
			}
		}
		queue = next
	}
	path := []string{start}
	for node := cameFrom[start]; node != start; node = cameFrom[node] {
		path = append(path, node)
	}
	path = append(path, start)
	for i, j := 0, len(path)-1; i < j; i, j = i+1, j-1 {
		path[i], path[j] = path[j], path[i]
	}
	return strings.Join(path, " -> ")
}

// backticked is packages as `a`, `b` and `c`.
func backticked(packages []string) string {
	quoted := make([]string, len(packages))
	for i, p := range packages {
		quoted[i] = "`" + p + "`"
	}
	if len(quoted) < 3 {
		return strings.Join(quoted, " and ")
	}
	return strings.Join(quoted[:len(quoted)-1], ", ") + " and " + quoted[len(quoted)-1]
}

// commonDir is the deepest directory every one of dirs is in or under.
func commonDir(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	common := strings.Split(dirs[0], "/")
	for _, d := range dirs[1:] {
		parts := strings.Split(d, "/")
		n := 0
		for n < len(common) && n < len(parts) && common[n] == parts[n] {
			n++
		}
		common = common[:n]
	}
	return strings.Join(common, "/")
}

// cycleCodegenImports is what is, the imports of a codegen rule of a member of
// is.cycle, resolves as: every member of the cycle, and what the members and
// the rule's sources import from outside it.
func (d *dartLang) cycleCodegenImports(is *importSet, from label.Label) *importSet {
	labels, out := d.cycles.members(is.cycle)
	in := map[string]bool{}
	for _, p := range is.cycle.Packages {
		in[p] = true
	}
	for pkg := range is.packages {
		if !in[pkg] {
			out.packages[pkg] = true
		}
	}
	for pkg, uris := range is.uris {
		if in[pkg] {
			continue
		}
		if out.uris[pkg] == nil {
			out.uris[pkg] = map[string]bool{}
		}
		for u := range uris {
			out.uris[pkg][u] = true
		}
	}
	out.labels = append(out.labels, is.labels...)
	for _, l := range labels {
		out.labels = append(out.labels, l.Rel(from.Repo, from.Pkg).String())
	}
	out.annotationPackage, out.annotationDefault = is.annotationPackage, is.annotationDefault
	return out
}
