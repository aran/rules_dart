package dart

import (
	"log"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/bazel-gazelle/walk"
)

// A Dart package is one `dart_library`: every file under its lib/, in the
// BUILD file at the package's root, as `pub.from_lock()` builds a pub
// package. Directories under lib/ mean nothing to Dart, to the analyzer or
// to build_modules, which groups a package's libraries by top-level
// directory alone, and import cycles inside a package are ordinary Dart. A
// source carrying a registered annotation is in it too, as are its parts,
// which the codegen targets beside it in that BUILD file generate
// (codegen.go).
//
// Gazelle reads the whole package from disk once per run, since the
// package's root holds what is under lib/ and a test can import a helper in
// another directory under test/. A test-tree directory a file in another
// directory imports from holds its helpers, and any test imported from
// elsewhere, in a `filegroup` named for the directory, visible to the
// package's test tree; a test lists it in `srcs` beside the files of its own
// directory it imports.

// scanState holds the scan of each package read in this Gazelle run.
type scanState struct {
	mu    sync.Mutex
	scans map[string]*packageScan // package root -> its scan
	// list reads a directory, repo-relative: the subdirectories and regular
	// files Gazelle sees. nil reads them as Gazelle's walk does, minus what
	// `# gazelle:exclude` excludes.
	list func(rel string) (dirs, files []string, err error)
}

// packageScan is what Gazelle reads of one Dart package's lib/ and test/.
type packageScan struct {
	// lib holds the sources under lib/ that Gazelle builds, repo-relative
	// and sorted by path: every Dart file there except those a codegen
	// target Gazelle writes produces.
	lib []DartFileInfo
	// annotated holds the registered annotations of each source in lib that
	// carries any, in the order the source states them.
	annotated map[string][]string
	// tests holds the sources of each test-tree directory, repo-relative.
	tests map[string][]DartFileInfo
	// lent holds what each test-tree directory that a file in another
	// directory imports from lends: its helpers (the files that are not
	// tests), and each test another directory imports.
	lent map[string][]DartFileInfo
	// executables reports whether the package has a Dart file outside its
	// lib/, test/ and hook/ -- at its root, under its bin/, tool/ or
	// example/ -- which Gazelle writes a `dart_binary` for.
	executables bool
}

// hasRules reports whether Gazelle writes any rule for the package's Dart
// files: its library, a test, a binary.
func (p *packageScan) hasRules() bool {
	return len(p.lib) > 0 || len(p.tests) > 0 || p.executables
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
	p := s.scanPackage(c, root)
	s.scans[root] = p
	return p
}

func (s *scanState) scanPackage(c *config.Config, root string) *packageScan {
	registry, _ := c.Exts[extKeyBuilderRegistry].(*builderRegistry)
	p := &packageScan{
		annotated: map[string][]string{},
		tests:     map[string][]DartFileInfo{},
		lent:      map[string][]DartFileInfo{},
	}

	// The directories of the package's lib/, of its test/, and the others
	// that hold Dart files: its root, bin/, tool/, example/ and the like.
	// Another package's root inside it ends its subtree.
	inPackage := func(layouts ...string) func(rel string) bool {
		return func(rel string) bool {
			if rel != root && hasPackageMetadata(c, rel) {
				return false
			}
			place := placeOf(c, rel)
			return place.Err == nil && place.Root == root && slices.Contains(layouts, place.Layout)
		}
	}

	// lib/: every source, then those Gazelle's codegen targets produce out.
	var all []DartFileInfo
	s.walkDartDirs(c, libDirOf(root), inPackage("lib"), func(rel string, files []DartFileInfo) {
		for _, f := range files {
			file := path.Join(rel, f.Path)
			all = append(all, DartFileInfo{Path: file, Imports: f.Imports})
			anns, err := ParseDartCodegenTriggers(filepath.Join(c.RepoRoot, filepath.FromSlash(file)))
			if err != nil {
				log.Printf("dart: %s: annotation parse failed: %v", file, err)
				continue
			}
			if reg := registeredAnnotations(anns, registry); len(reg) > 0 {
				p.annotated[file] = reg
			}
		}
	})
	produced := map[string]bool{}
	for file, anns := range p.annotated {
		for _, out := range producedFiles(file, anns, registry) {
			produced[out] = true
		}
	}
	for _, f := range all {
		if !produced[f.Path] {
			p.lib = append(p.lib, f)
		}
	}
	sort.Slice(p.lib, func(i, j int) bool { return p.lib[i].Path < p.lib[j].Path })

	// test/: the sources of each directory, and what each lends the others.
	s.walkDartDirs(c, path.Join(root, "test"), inPackage("test"), func(rel string, files []DartFileInfo) {
		for _, f := range files {
			p.tests[rel] = append(p.tests[rel], DartFileInfo{Path: path.Join(rel, f.Path), Imports: f.Imports})
		}
	})
	// Every other directory, for whether any holds a Dart file.
	s.walkDirs(c, root, inPackage("", "bin"), func(_ string, names []string) {
		p.executables = p.executables || HasDartFiles(names)
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

// registeredAnnotations is the annotations that have a registered builder,
// each once, in the order given.
func registeredAnnotations(anns []string, registry *builderRegistry) []string {
	var out []string
	seen := map[string]bool{}
	for _, a := range anns {
		if !seen[a] && registry.lookup(a) != nil {
			seen[a] = true
			out = append(out, a)
		}
	}
	return out
}

// producedFiles is the source-tree path of each Dart file the codegen
// targets Gazelle writes for the source at file, which carries the
// registered annotations anns, produce: a SharedPart builder's shard is
// combined into the source's `.g.dart`, any other builder writes its own
// extensions. A file of that path in the source tree is the output checked
// in, as a published package carries it, and is no source of the library.
func producedFiles(file string, anns []string, registry *builderRegistry) []string {
	stem := strings.TrimSuffix(file, ".dart")
	var out []string
	for _, a := range anns {
		for _, b := range registry.lookup(a) {
			if b.SharedPart {
				out = append(out, stem+".g.dart")
				continue
			}
			for _, ext := range b.Produces {
				out = append(out, stem+ext)
			}
		}
	}
	return out
}

// walkDartDirs calls each with the Dart files of every directory at or under
// top that keep allows, a directory keep refuses ending its subtree
// (`walkDirs`).
func (s *scanState) walkDartDirs(c *config.Config, top string, keep func(rel string) bool, each func(rel string, files []DartFileInfo)) {
	s.walkDirs(c, top, keep, func(rel string, names []string) {
		files, _ := ParseDartDir(filepath.Join(c.RepoRoot, filepath.FromSlash(rel)), names)
		if len(files) > 0 {
			each(rel, files)
		}
	})
}

// walkDirs calls each with the regular files of every directory at or under
// top that keep allows, a directory keep refuses ending its subtree. Hidden
// directories, excluded ones and the ones holding a different Bazel
// repository are skipped.
func (s *scanState) walkDirs(c *config.Config, top string, keep func(rel string) bool, each func(rel string, names []string)) {
	list := s.list
	if list == nil {
		list = gazelleDir
	}
	var visit func(rel string)
	visit = func(rel string) {
		if !keep(rel) {
			return
		}
		dirs, names, err := list(rel)
		if err != nil {
			return
		}
		if rel != top {
			for _, n := range names {
				if n == "MODULE.bazel" || n == "REPO.bazel" || n == "WORKSPACE" || n == "WORKSPACE.bazel" {
					return
				}
			}
		}
		each(rel, names)
		for _, d := range dirs {
			if !strings.HasPrefix(d, ".") {
				visit(path.Join(rel, d))
			}
		}
	}
	visit(top)
}

// hasPackageMetadata reports whether the BUILD file of directory rel
// declares a `dart_package_metadata`, which roots a package there.
func hasPackageMetadata(c *config.Config, rel string) bool {
	dir := filepath.Join(c.RepoRoot, filepath.FromSlash(rel))
	for _, name := range c.ValidBuildFileNames {
		f, err := rule.LoadFile(filepath.Join(dir, name), rel)
		if err != nil {
			continue
		}
		for _, r := range f.Rules {
			if r.Kind() == "dart_package_metadata" {
				return true
			}
		}
		return false
	}
	return false
}

// gazelleDir is a directory's subdirectories and regular files as Gazelle's
// walk sees them, sorted.
func gazelleDir(rel string) ([]string, []string, error) {
	di, err := walk.GetDirInfo(rel)
	if err != nil {
		return nil, nil, err
	}
	dirs := append([]string(nil), di.Subdirs...)
	files := append([]string(nil), di.RegularFiles...)
	sort.Strings(dirs)
	sort.Strings(files)
	return dirs, files, nil
}

// osDir is a directory's subdirectories and regular files as the file
// system has them, sorted: what Gazelle's walk sees with nothing excluded.
func osDir(repoRoot string) func(rel string) ([]string, []string, error) {
	return func(rel string) ([]string, []string, error) {
		ents, err := os.ReadDir(filepath.Join(repoRoot, filepath.FromSlash(rel)))
		if err != nil {
			return nil, nil, err
		}
		var dirs, files []string
		for _, e := range ents {
			switch {
			case e.IsDir():
				dirs = append(dirs, e.Name())
			case e.Type().IsRegular():
				files = append(files, e.Name())
			}
		}
		return dirs, files, nil
	}
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

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// dirLabel is the label of the target named for directory dir, relative to
// the Bazel package from: `//test/support` for the `support` filegroup.
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
