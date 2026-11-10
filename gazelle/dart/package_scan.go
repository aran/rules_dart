package dart

import (
	"io/fs"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// A Dart package's directories can need each other's files, which no single
// directory's sources show: two directories under lib/ whose libraries
// import each other, directly or through a chain, and a test that imports a
// helper in another directory under test/. Gazelle reads the whole package
// from disk once per run to see that, and each directory takes its share.
//
// Library directories that import each other (a strongly connected
// component of the import graph between a package's lib/ directories) are
// one `dart_library`, since Bazel builds no cycle; it is the same answer
// `pub.from_lock()` gives packages that depend on each other. The library is
// the one of the directory nearest the package's lib/ (by depth, then by
// path), so it keeps that directory's name: the package's own library when
// lib/ is in the cycle. Every other directory of the cycle holds its sources
// in a `filegroup` named for the directory, visible to that library only,
// which lists it in `srcs`. A directory in no cycle has its own library.
//
// A test-tree directory a file in another directory imports from holds its
// helpers, and any test imported from elsewhere, in a `filegroup` named for
// the directory, visible to the package's test tree; a test lists it in
// `srcs` beside the files of its own directory it imports.

// scanState holds the scan of each package read in this Gazelle run.
type scanState struct {
	mu    sync.Mutex
	scans map[string]*packageScan // package root -> its scan
}

// packageScan is what Gazelle reads of one Dart package's lib/ and test/.
type packageScan struct {
	// lib holds the plain sources of each lib/ directory: those no
	// generator writes or reads. Paths are repo-relative.
	lib map[string][]DartFileInfo
	// groups is the cycle of each lib/ directory in one.
	groups map[string]*libGroup
	// tests holds the sources of each test-tree directory, repo-relative.
	tests map[string][]DartFileInfo
	// lent holds what each test-tree directory that a file in another
	// directory imports from lends: its helpers (the files that are not
	// tests), and each test another directory imports.
	lent map[string][]DartFileInfo
}

// libGroup is a cycle of lib/ directories, held by the library of Owner.
type libGroup struct {
	Owner   string
	Members []string // sorted, Owner among them
}

// scanOf returns the scan of the package rooted at root, reading it on
// first use.
func (s *scanState) scanOf(c *config.Config, root string) *packageScan {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.scans[root]; ok {
		return p
	}
	if s.scans == nil {
		s.scans = map[string]*packageScan{}
	}
	p := scanPackage(c, root)
	s.scans[root] = p
	return p
}

func scanPackage(c *config.Config, root string) *packageScan {
	registry, _ := c.Exts[extKeyBuilderRegistry].(*builderRegistry)
	self := libraryName(root, c)
	p := &packageScan{
		lib:    map[string][]DartFileInfo{},
		groups: map[string]*libGroup{},
		tests:  map[string][]DartFileInfo{},
		lent:   map[string][]DartFileInfo{},
	}

	// lib/: the plain sources of each directory, and the parts each names.
	parts := map[string][]string{}
	walkDartDirs(c, libDirOf(root), func(rel string) bool {
		return placeDir(rel).Err == nil
	}, func(rel string, files []DartFileInfo) {
		var plain []DartFileInfo
		for _, f := range filterOutGeneratedFiles(files, registry) {
			anns, err := ParseDartCodegenTriggers(filepath.Join(c.RepoRoot, filepath.FromSlash(rel), f.Path))
			if err == nil && hasRegistered(anns, registry) {
				continue
			}
			file := path.Join(rel, f.Path)
			plain = append(plain, DartFileInfo{Path: file, Imports: f.Imports})
			uris, _ := ParseDartParts(filepath.Join(c.RepoRoot, filepath.FromSlash(file)))
			for _, u := range uris {
				if part := ownFile(self, root, file, classifyURI(u)); part != "" {
					parts[file] = append(parts[file], part)
				}
			}
		}
		if len(plain) > 0 {
			p.lib[rel] = plain
		}
	})
	for _, g := range libraryGroups(self, root, p.lib, parts) {
		for _, m := range g.Members {
			p.groups[m] = g
		}
	}

	// test/: the sources of each directory, and what each lends the others.
	walkDartDirs(c, path.Join(root, "test"), func(rel string) bool {
		layout, r := layoutOf(rel)
		return layout == "test" && r == root
	}, func(rel string, files []DartFileInfo) {
		for _, f := range filterOutGeneratedFiles(files, registry) {
			p.tests[rel] = append(p.tests[rel], DartFileInfo{Path: path.Join(rel, f.Path), Imports: f.Imports})
		}
	})
	imported := map[string]bool{}
	for dir, files := range p.tests {
		for _, f := range files {
			for _, imp := range f.Imports {
				if to, ok := p.testDirOf(relativeTarget(f.Path, imp)); ok && to != dir {
					imported[relativeTarget(f.Path, imp)] = true
					imported[to] = true
				}
			}
		}
	}
	for dir, files := range p.tests {
		if !imported[dir] {
			continue
		}
		for _, f := range files {
			if !strings.HasSuffix(f.Path, "_test.dart") || imported[f.Path] {
				p.lent[dir] = append(p.lent[dir], f)
			}
		}
	}
	return p
}

// libraryGroups decides the package's library granularity: which lib/
// directories (keys of lib, holding their plain sources) share one
// `dart_library`, and which directory's library that is. A directory in no
// group has a library of its own. This is the one place the granularity is
// decided; generation and resolution follow whatever groups it returns.
//
// Today a group is a cycle of directories that import each other (a strongly
// connected component of the import graph between directories), held by the
// directory nearest lib/, by depth and then by path. A part (parts maps a
// file to the repo-relative parts it names) is in its library's target, so
// the directories of a library and of its part are a cycle too.
func libraryGroups(self, root string, lib map[string][]DartFileInfo, parts map[string][]string) []*libGroup {
	held := map[string]bool{}
	for _, files := range lib {
		for _, f := range files {
			held[f.Path] = true
		}
	}
	seen := map[[2]string]bool{}
	edges := map[string][]string{}
	edge := func(from, to string) {
		if from != to && !seen[[2]string{from, to}] {
			seen[[2]string{from, to}] = true
			edges[from] = append(edges[from], to)
		}
	}
	for dir, files := range lib {
		for _, f := range files {
			for _, imp := range f.Imports {
				if target := ownFile(self, root, f.Path, imp); held[target] {
					edge(dir, path.Dir(target))
				}
			}
			for _, part := range parts[f.Path] {
				if held[part] {
					edge(dir, path.Dir(part))
					edge(path.Dir(part), dir)
				}
			}
		}
	}
	for dir := range edges {
		sort.Strings(edges[dir])
	}
	var groups []*libGroup
	for _, scc := range stronglyConnected(sortedKeys(lib), edges) {
		if len(scc) < 2 {
			continue
		}
		sort.Strings(scc)
		owner := scc[0]
		for _, m := range scc[1:] {
			if depth(m) < depth(owner) {
				owner = m
			}
		}
		groups = append(groups, &libGroup{Owner: owner, Members: scc})
	}
	return groups
}

// libShare is what a lib/ directory's plain sources go into (libraryGroups):
// lendTo, the directory whose library holds them, when that is another's;
// else the labels of the filegroups its own library lists in `srcs`, and
// the repo-relative files those hold.
func (p *packageScan) libShare(rel string) (lendTo string, lent []string, files []DartFileInfo) {
	g := p.groups[rel]
	if g == nil {
		return "", nil, nil
	}
	if g.Owner != rel {
		return g.Owner, nil, nil
	}
	for _, m := range g.Members {
		if m != rel {
			lent = append(lent, dirLabel(m, rel))
			files = append(files, p.lib[m]...)
		}
	}
	sort.Strings(lent)
	return "", lent, files
}

// walkDartDirs calls each with the Dart files of every directory at or under
// top that keep allows, a directory keep refuses ending its subtree. Hidden
// directories and the ones holding a different Bazel repository are skipped.
func walkDartDirs(c *config.Config, top string, keep func(rel string) bool, each func(rel string, files []DartFileInfo)) {
	abs := filepath.Join(c.RepoRoot, filepath.FromSlash(top))
	_ = filepath.WalkDir(abs, func(p string, e fs.DirEntry, err error) error {
		if err != nil || !e.IsDir() {
			return nil
		}
		rel, rerr := filepath.Rel(c.RepoRoot, p)
		if rerr != nil {
			return fs.SkipDir
		}
		rel = filepath.ToSlash(rel)
		if (p != abs && strings.HasPrefix(e.Name(), ".")) || !keep(rel) {
			return fs.SkipDir
		}
		ents, rerr := readDirNames(p)
		if rerr != nil {
			log.Printf("dart: reading %s: %v", rel, rerr)
			return nil
		}
		for _, n := range ents {
			if n == "MODULE.bazel" || n == "REPO.bazel" || n == "WORKSPACE" || n == "WORKSPACE.bazel" {
				return fs.SkipDir
			}
		}
		files, _ := ParseDartDir(p, ents)
		if len(files) > 0 {
			each(rel, files)
		}
		return nil
	})
}

func readDirNames(dir string) ([]string, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if e.Type().IsRegular() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// hasRegistered reports whether any annotation has a registered builder.
func hasRegistered(anns []string, registry *builderRegistry) bool {
	for _, a := range anns {
		if registry.lookup(a) != nil {
			return true
		}
	}
	return false
}

// ownFile is the repo-relative path of the file of the package (named self,
// rooted at root) that an import in the repo-relative file names, or "".
func ownFile(self, root, file string, imp DartImport) string {
	uri := importedURI(self, root, file, imp)
	prefix := "package:" + self + "/"
	if !strings.HasPrefix(uri, prefix) {
		return ""
	}
	return libDirOf(root) + "/" + strings.TrimPrefix(uri, prefix)
}

// relativeTarget is the repo-relative path a relative import in the
// repo-relative file names, or "" for any other import.
func relativeTarget(file string, imp DartImport) string {
	if !imp.IsRelative || strings.Contains(imp.URI, ":") {
		return ""
	}
	return path.Clean(path.Join(path.Dir(file), imp.URI))
}

// testDirOf is the test-tree directory holding the repo-relative file, when
// one does.
func (p *packageScan) testDirOf(file string) (string, bool) {
	if file == "" {
		return "", false
	}
	dir := path.Dir(file)
	for _, f := range p.tests[dir] {
		if f.Path == file {
			return dir, true
		}
	}
	return "", false
}

// stronglyConnected returns the strongly connected components of the graph
// (Tarjan), each node in exactly one, visiting nodes in the given order.
func stronglyConnected(nodes []string, edges map[string][]string) [][]string {
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
		for _, w := range edges[v] {
			if _, ok := index[w]; !ok {
				visit(w)
				low[v] = min(low[v], low[w])
			} else if onStack[w] {
				low[v] = min(low[v], index[w])
			}
		}
		if low[v] == index[v] {
			var scc []string
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[w] = false
				scc = append(scc, w)
				if w == v {
					break
				}
			}
			out = append(out, scc)
		}
	}
	for _, v := range nodes {
		if _, ok := index[v]; !ok {
			visit(v)
		}
	}
	return out
}

func depth(rel string) int { return strings.Count(rel, "/") }

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// dirLabel is the label of the target named for directory dir, relative to
// the Bazel package from: `//lib/src/model` for the `model` filegroup.
func dirLabel(dir, from string) string {
	return label.New("", dir, path.Base(dir)).Rel("", from).String()
}

// sourcesFilegroup is the filegroup named for directory rel holding its
// files, visible to visibility.
func sourcesFilegroup(rel string, files []DartFileInfo, visibility string) *rule.Rule {
	r := rule.NewRule("filegroup", path.Base(rel))
	srcs := make([]string, len(files))
	for i, f := range files {
		srcs[i] = path.Base(f.Path)
	}
	sort.Strings(srcs)
	r.SetAttr("srcs", srcs)
	r.SetAttr("visibility", []string{visibility})
	return r
}

// staleFilegroups returns an empty-rule marker for the filegroup named for
// directory rel, the one Gazelle writes, when this pass did not generate it.
func staleFilegroups(f *rule.File, rel string, gen []*rule.Rule) []*rule.Rule {
	if f == nil || rel == "" {
		return nil
	}
	name := path.Base(rel)
	for _, r := range gen {
		if r.Name() == name {
			return nil
		}
	}
	for _, r := range f.Rules {
		if r.Kind() == "filegroup" && r.Name() == name {
			return []*rule.Rule{rule.NewRule("filegroup", name)}
		}
	}
	return nil
}
