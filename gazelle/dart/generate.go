package dart

import (
	"fmt"
	"log"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// GenerateRules generates Dart BUILD rules for a directory: the Dart targets,
// then the analysis options targets (analysis_options.go), then the cycles
// its directives declare (cycle.go).
func (d *dartLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	res := d.generateDartRules(args)
	// After any codegen of the directory has read its build.yaml.
	d.checkIgnores(args.Config, args.Rel)
	taken := map[string]bool{}
	for _, r := range res.Gen {
		taken[r.Name()] = true
	}
	gen, imports, empty := d.analysisRules(args, taken)
	res.Gen = append(res.Gen, gen...)
	res.Imports = append(res.Imports, imports...)
	res.Empty = append(res.Empty, empty...)
	// After the directories below, whose members a cycle here builds.
	gen, imports, empty = d.cycleRules(args)
	res.Gen = append(res.Gen, gen...)
	res.Imports = append(res.Imports, imports...)
	res.Empty = append(res.Empty, empty...)
	return res
}

func (d *dartLang) generateDartRules(args language.GenerateArgs) language.GenerateResult {
	place := placeOf(args.Config, args.Rel)
	switch {
	case place.Err != nil:
	case place.Layout == "hook":
		return hookRules(args, place.Root)
	case place.Layout == "lib":
		// The package's library, at its root, holds what is under lib/.
		return d.libDirRules(args, place.Root)
	}
	dartFiles, _ := ParseDartDir(args.Dir, args.RegularFiles)
	if place.Err != nil {
		if len(dartFiles) > 0 {
			log.Printf("dart: %v; no dart_library generated for %s", place.Err, strings.Join(fileNames(dartFiles), ", "))
		}
		return language.GenerateResult{}
	}

	// The library of the package rooted here, when it has a lib/, and the
	// package's facts.
	root, layout := place.Root, place.Layout
	var gen []*rule.Rule
	var imports []interface{}
	var staleLibs []*rule.Rule
	if args.Rel == root {
		if hasFile(args.Subdirs, "lib") {
			gen, imports, staleLibs = d.packageLibraryRules(args)
		}
		if m := d.metadataOf(args.Config, root); m != nil {
			gen = append([]*rule.Rule{d.metadataRule(args.Config, root, m, args.File)}, gen...)
			imports = append([]interface{}{nil}, imports...)
		}
	}
	if len(dartFiles) == 0 && len(gen) == 0 {
		return language.GenerateResult{}
	}
	d.checkAgreement(args)

	// Classify files by the conventional directory of their package.
	var libFiles, binFiles, testFiles []DartFileInfo
	helpers := map[string]DartFileInfo{}
	for _, f := range dartFiles {
		switch {
		case isTestFile(f):
			testFiles = append(testFiles, f)
		case layout == "test":
			// package:test runs only `_test.dart` files; the others in
			// test/ are helpers, part of each test that imports them.
			helpers[f.Path] = f
		case layout == "bin":
			binFiles = append(binFiles, f)
		default:
			libFiles = append(libFiles, f)
		}
	}

	// Dart files of a directory in no package's lib/, bin/ or test/
	// (tool/, example/): scripts, as `dart run tool/x.dart` runs them.
	var stale []*rule.Rule
	if len(libFiles) > 0 {
		scripts, scriptImports, old := d.scriptRules(args, root, libFiles, gen)
		gen = append(gen, scripts...)
		imports = append(imports, scriptImports...)
		stale = old
	}

	// A test-tree directory another directory imports from holds what it
	// lends (package_scan.go).
	if layout == "test" {
		scan := d.scan.scanOf(args.Config, root)
		if lent := scan.lent[args.Rel]; len(lent) > 0 {
			gen = append(gen, sourcesFilegroup(args.Rel, lent,
				label.New("", path.Join(root, "test"), "__subpackages__").String()))
			imports = append(imports, nil)
		}
	}

	if len(binFiles) > 0 {
		bins, binImports := d.binaryRules(args, root, binFiles)
		gen = append(gen, bins...)
		imports = append(imports, binImports...)
		stale = append(stale, partBinaries(args.File, binFiles)...)
	}

	for _, f := range testFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_test", name)
		r.SetAttr("main", f.Path)
		srcs, files := d.testHelpers(args, f)
		if len(srcs) > 0 {
			r.SetAttr("srcs", srcs)
		}
		tags := testTags(args, f)
		if len(tags) > 0 {
			r.SetAttr("tags", tags)
		}
		d.setTestPlatforms(args, f, r)
		d.setPackage(r, args.Config, root, args.Rel)
		gen = append(gen, r)
		imports = append(imports, collectRepoImports(args, files))
	}

	empty := append(staleCodegenRules(args.File, gen, deletableKinds(d.builders())), helperTests(args.File, helpers)...)
	empty = append(append(empty, stale...), staleLibs...)
	if layout == "test" {
		empty = append(empty, staleFilegroups(args.File, args.Rel, gen)...)
	}
	return language.GenerateResult{
		Gen:     gen,
		Imports: imports,
		Empty:   empty,
	}
}

// packageLibraryRules is what Gazelle writes, in the BUILD file at the root
// of a package (args.Rel), for the package's lib/: the package's
// `dart_library`, holding every source under lib/ and what the codegen
// targets of the sources carrying registered annotations generate, and those
// targets (codegen.go). It returns too the per-source libraries earlier
// Gazelle versions wrote for annotated sources, to delete.
func (d *dartLang) packageLibraryRules(args language.GenerateArgs) ([]*rule.Rule, []interface{}, []*rule.Rule) {
	root := args.Rel
	scan := d.scan.scanOf(args.Config, root)
	if len(scan.lib) == 0 {
		return nil, nil, nil
	}
	registry, _ := args.Config.Exts[extKeyBuilderRegistry].(*builderRegistry)
	if len(scan.annotated) > 0 {
		// The options the package's build.yaml states for the builders.
		registry = d.withBuildYaml(args, registry, scan)
	}
	gen, imports, genSrcs, runtime := d.codegenRules(args, scan, registry)

	r := rule.NewRule("dart_library", libraryName(root, args.Config))
	d.setPackage(r, args.Config, root, args.Rel)
	srcs := make([]string, 0, len(scan.lib)+len(genSrcs))
	for _, f := range scan.lib {
		srcs = append(srcs, relTo(root, f.Path))
	}
	r.SetAttr("srcs", append(srcs, genSrcs...))
	// The link hook's imports are the library's dependencies (hook.go).
	files := append(append([]DartFileInfo(nil), scan.lib...), d.scan.linkHookImports(args.Config.RepoRoot, root, r.Name())...)
	r.SetAttr("visibility", []string{"//visibility:public"})
	is := collectRepoImports(args, files)
	// What the builders generate imports their runtime libraries.
	addRuntimeDeps(is, runtime)
	// A package of a declared cycle is a member of it instead (cycle.go).
	lib, libImports, replaced := d.cycleMemberRules(args, root, r, is, genSrcs, gen, imports)
	gen = append(gen, lib...)
	imports = append(imports, libImports...)
	return gen, imports, append(staleSourceLibraries(args.File, root, scan, r.Name()), replaced...)
}

// staleSourceLibraries returns an empty-rule marker for each library in f, the
// BUILD file at the package's root, that earlier Gazelle versions wrote for
// an annotated source: named for its path under lib/ and holding it. The
// package's library holds the source now. `# keep` keeps one.
func staleSourceLibraries(f *rule.File, root string, scan *packageScan, pkgLib string) []*rule.Rule {
	if f == nil {
		return nil
	}
	var empty []*rule.Rule
	for _, r := range f.Rules {
		if r.Kind() != "dart_library" || r.Name() == pkgLib || r.ShouldKeep() {
			continue
		}
		for file := range scan.annotated {
			src := relTo(root, file)
			if r.Name() == libStem(src) && hasFile(r.AttrStrings("srcs"), src) {
				empty = append(empty, rule.NewRule("dart_library", r.Name()))
				break
			}
		}
	}
	return empty
}

// binaryRules is what Gazelle writes for the Dart files of a bin/ directory:
// a `dart_binary` for each file that is not a part, holding in `srcs` each
// file of the directory it reaches by relative imports and parts. A part no
// binary reaches is an error naming it, since nothing could build it.
func (d *dartLang) binaryRules(args language.GenerateArgs, root string, files []DartFileInfo) ([]*rule.Rule, []interface{}) {
	byPath := filesByPath(args.Rel, files)
	reached := map[string]bool{}
	var gen []*rule.Rule
	var imports []interface{}
	for _, f := range files {
		if f.IsPart {
			continue
		}
		r, is := d.programRule(args, root, f, byPath, reached)
		gen = append(gen, r)
		imports = append(imports, is)
	}
	for _, f := range sortedKeys(byPath) {
		if byPath[f].IsPart && !reached[f] {
			d.errs.add(unreachedPartError(f, "binary"))
		}
	}
	return gen, imports
}

// programRule is the `dart_binary` of the file f of directory args.Rel, whose
// files are byPath, and what it imports. The files it holds go in reached.
func (d *dartLang) programRule(args language.GenerateArgs, root string, f DartFileInfo, byPath map[string]DartFileInfo, reached map[string]bool) (*rule.Rule, *importSet) {
	main := byPath[path.Join(args.Rel, f.Path)]
	reached[main.Path] = true
	held := filesReached(main, byPath)
	var srcs []string
	for _, h := range held[1:] {
		reached[h.Path] = true
		srcs = append(srcs, path.Base(h.Path))
	}
	r := rule.NewRule("dart_binary", strings.TrimSuffix(f.Path, ".dart"))
	r.SetAttr("main", f.Path)
	if len(srcs) > 0 {
		sort.Strings(srcs)
		r.SetAttr("srcs", srcs)
	}
	d.setPackage(r, args.Config, root, args.Rel)
	return r, collectRepoImports(args, held)
}

// filesByPath is files, of directory rel, by repo-relative path, each named
// by it.
func filesByPath(rel string, files []DartFileInfo) map[string]DartFileInfo {
	byPath := map[string]DartFileInfo{}
	for _, f := range repoFiles(rel, files) {
		byPath[f.Path] = f
	}
	return byPath
}

// filesReached is main, then each file of byPath it reaches through relative
// imports, exports and parts.
func filesReached(main DartFileInfo, byPath map[string]DartFileInfo) []DartFileInfo {
	held := []DartFileInfo{main}
	var visit func(DartFileInfo)
	visit = func(g DartFileInfo) {
		for _, imp := range g.Imports {
			h, ok := byPath[relativeTarget(g.Path, imp)]
			if !ok || containsFile(held, h.Path) {
				continue
			}
			held = append(held, h)
			visit(h)
		}
	}
	visit(main)
	return held
}

// declaresMain reports whether the library of the file f of directory dir, the
// file and its parts, has a top-level `main`.
func declaresMain(dir string, f DartFileInfo, byPath map[string]DartFileInfo) bool {
	if HasTopLevelMain(filepath.Join(dir, path.Base(f.Path))) {
		return true
	}
	seen := map[string]bool{f.Path: true}
	var inParts func(DartFileInfo) bool
	inParts = func(g DartFileInfo) bool {
		for _, imp := range g.Imports {
			h, ok := byPath[relativeTarget(g.Path, imp)]
			if !imp.IsPart || !ok || seen[h.Path] {
				continue
			}
			seen[h.Path] = true
			if HasTopLevelMain(filepath.Join(dir, path.Base(h.Path))) || inParts(h) {
				return true
			}
		}
		return false
	}
	return inParts(f)
}

// unreachedPartError is the error for the part at file, which no program of
// its directory, each a kind, includes.
func unreachedPartError(file, kind string) string {
	return fmt.Sprintf("dart: %s is a part, and no %s beside it reaches it; "+
		"name it in a `part` directive of a file beside it that one reaches, or "+
		"exclude it with `# gazelle:exclude`", file, kind)
}

// partBinaries returns an empty-rule marker for each existing dart_binary
// whose main is one of files that is a part, which earlier Gazelle versions
// wrote: a part cannot be compiled alone. `# keep` keeps one.
func partBinaries(f *rule.File, files []DartFileInfo) []*rule.Rule {
	if f == nil {
		return nil
	}
	parts := map[string]bool{}
	for _, file := range files {
		parts[file.Path] = file.IsPart
	}
	var empty []*rule.Rule
	for _, r := range f.Rules {
		if r.Kind() == "dart_binary" && parts[r.AttrString("main")] && !r.ShouldKeep() {
			empty = append(empty, rule.NewRule("dart_binary", r.Name()))
		}
	}
	return empty
}

// scriptRules is what Gazelle writes for the Dart files of a directory in
// no package's lib/, bin/ or test/ (tool/, example/), which are scripts: a
// `dart_binary` for each file that is no part and whose library has a
// top-level `main`, holding in `srcs` each file of the directory it reaches
// by relative imports and parts. A file no binary reaches is an error naming
// it, since nothing could build it. A `dart_library` of the directory's own
// files, which earlier Gazelle versions wrote and `dart_library` refuses
// outside lib/, is deleted, as is a `dart_binary` of a part.
func (d *dartLang) scriptRules(args language.GenerateArgs, root string, files []DartFileInfo, taken []*rule.Rule) ([]*rule.Rule, []interface{}, []*rule.Rule) {
	byPath := filesByPath(args.Rel, files)
	reached := map[string]bool{}
	var gen []*rule.Rule
	var imports []interface{}
	for _, f := range files {
		main := byPath[path.Join(args.Rel, f.Path)]
		if f.IsPart || !declaresMain(args.Dir, main, byPath) {
			continue
		}
		r, is := d.programRule(args, root, f, byPath, reached)
		if ruleNamed(taken, r.Name()) != nil {
			d.errs.add(fmt.Sprintf(
				"dart: %s: its `dart_binary` would be named %q, as the package's "+
					"library is; rename the file", main.Path, r.Name()))
			continue
		}
		gen = append(gen, r)
		imports = append(imports, is)
	}
	for _, f := range sortedKeys(byPath) {
		if reached[f] {
			continue
		}
		if lib := strayLib(root, args.Rel); lib != "" {
			d.errs.add(fmt.Sprintf(
				"dart: %s is under %s, which is no package's lib/: the package "+
					"rooted at %s has its lib/ at %s; make %s a package of its own "+
					"with a pubspec.yaml or a `dart_package_metadata`, or move the file",
				f, lib, dirName(root), libDirOf(root), dirName(path.Dir(lib))))
			continue
		}
		if byPath[f].IsPart {
			d.errs.add(unreachedPartError(f, "script"))
			continue
		}
		d.errs.add(fmt.Sprintf(
			"dart: %s is in no package's lib/, bin/ or test/, has no top-level "+
				"`main`, and no script beside it imports it; move it into lib/ or "+
				"beside the script that uses it, or exclude it with `# gazelle:exclude`",
			f))
	}
	var stale []*rule.Rule
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "dart_library" && !r.ShouldKeep() && ownSources(r, args.RegularFiles) {
				stale = append(stale, rule.NewRule("dart_library", r.Name()))
			}
		}
	}
	return gen, imports, append(stale, partBinaries(args.File, files)...)
}

// strayLib is the directory named `lib` that directory rel, in the package
// rooted at root, is in or under below the root, when it is in one: a lib/
// of no package, since the package's own is its root's.
func strayLib(root, rel string) string {
	if rel == root {
		return ""
	}
	parts := strings.Split(relTo(root, rel), "/")
	for i, p := range parts {
		if p == "lib" {
			return path.Join(root, strings.Join(parts[:i+1], "/"))
		}
	}
	return ""
}

func containsFile(files []DartFileInfo, p string) bool {
	for _, f := range files {
		if f.Path == p {
			return true
		}
	}
	return false
}

// libStem names what Gazelle writes for a source under lib/, named from the
// package's root: its path under lib/, without `.dart` (`src/model/user`
// for `lib/src/model/user.dart`), unique in the package as the path is.
func libStem(file string) string {
	return strings.TrimSuffix(strings.TrimPrefix(file, "lib/"), ".dart")
}

// relTo is the repo-relative file named from directory rel, which holds it.
func relTo(rel, file string) string {
	if rel == "" {
		return file
	}
	return strings.TrimPrefix(file, rel+"/")
}

func ruleNamed(rules []*rule.Rule, name string) *rule.Rule {
	for _, r := range rules {
		if r.Name() == name {
			return r
		}
	}
	return nil
}

// testHelpers is what a test reaches through relative imports and parts, its
// own or those of the files it reaches: the `srcs` of its dart_test, sorted -- each
// file of its own directory, and the filegroup of each other test-tree
// directory of its package it reaches a file of (package_scan.go) -- and
// those files, the test first, repo-relative, whose imports are its deps. The
// other files of a filegroup are in `srcs` but not in its program, so they
// add no dep. A relative import of a file in another directory that no rule
// holds is logged.
func (d *dartLang) testHelpers(args language.GenerateArgs, test DartFileInfo) ([]string, []DartFileInfo) {
	root, _ := packageRootOf(args.Config, args.Rel)
	scan := d.scan.scanOf(args.Config, root)
	self := packageNameIn(args.Config, args.Rel)
	main := test.at(path.Join(args.Rel, test.Path))
	files := []DartFileInfo{main}
	seen := map[string]bool{main.Path: true}
	var own, lent []string
	var visit func(f DartFileInfo)
	add := func(f DartFileInfo) {
		if !seen[f.Path] {
			seen[f.Path] = true
			files = append(files, f)
			visit(f)
		}
	}
	visit = func(f DartFileInfo) {
		for _, imp := range f.Imports {
			target := relativeTarget(f.Path, imp)
			if target == "" {
				continue
			}
			dir, ok := scan.testDirOf(target)
			switch {
			case ok && dir == args.Rel:
				for _, h := range scan.tests[dir] {
					if h.Path == target && !seen[h.Path] {
						own = append(own, path.Base(h.Path))
						add(h)
					}
				}
			case ok && lentFile(scan.lent[dir], target) != nil:
				if !seen["//"+dir] {
					seen["//"+dir] = true
					lent = append(lent, dirLabel(dir, args.Rel))
				}
				add(*lentFile(scan.lent[dir], target))
			case importedURI(self, root, f.Path, imp) != "":
			case path.Dir(target) != path.Dir(f.Path):
				log.Printf("dart: %s imports %s, which is in no rule; add a "+
					"rule holding it to the srcs of %q by hand and mark it `# keep`",
					f.Path, imp.URI, strings.TrimSuffix(test.Path, ".dart"))
			}
		}
	}
	visit(main)
	sort.Strings(own)
	sort.Strings(lent)
	return append(own, lent...), files
}

// lentFile is the file at path among those a directory lends, or nil.
func lentFile(lent []DartFileInfo, path string) *DartFileInfo {
	for i := range lent {
		if lent[i].Path == path {
			return &lent[i]
		}
	}
	return nil
}

// helperTests returns empty-rule markers for each existing dart_test whose
// main is a helper: a file package:test never runs, so not a test.
// `# keep` keeps one written by hand.
func helperTests(f *rule.File, helpers map[string]DartFileInfo) []*rule.Rule {
	if f == nil {
		return nil
	}
	var empty []*rule.Rule
	for _, r := range f.Rules {
		if r.Kind() != "dart_test" {
			continue
		}
		if _, ok := helpers[r.AttrString("main")]; ok {
			empty = append(empty, rule.NewRule("dart_test", r.Name()))
		}
	}
	return empty
}

// testTags returns the Bazel tags for a test file's dart_test: the file's
// suite-level package:test `@Tags`. Problems with the annotation, and
// existing tags the merge is about to drop, are logged.
func testTags(args language.GenerateArgs, f DartFileInfo) []string {
	rel := path.Join(args.Rel, f.Path)
	tags, problems, err := ParseDartTestTags(filepath.Join(args.Dir, f.Path))
	if err != nil {
		log.Printf("dart: %s: reading @Tags failed: %v", rel, err)
		return nil
	}
	for _, p := range problems {
		log.Printf("dart: %s: %s", rel, p)
	}
	if args.File != nil {
		name := strings.TrimSuffix(f.Path, ".dart")
		for _, existing := range args.File.Rules {
			if existing.Name() != name {
				continue
			}
			for _, t := range droppedHandTags(existing, tags) {
				log.Printf("dart: %s: removing tag %q from %q, which the file's "+
					"@Tags does not give; mark it `# keep` if it was written by hand",
					rel, t, existing.Name())
			}
		}
	}
	return tags
}

// deletableKinds is the set of rule kinds Gazelle may delete when a
// previously generated rule is no longer produced (e.g. an annotation was
// removed from the source). Deliberately limited to the convenience-macro
// kinds and the codegen primitives Gazelle synthesizes itself:
// dart_library / dart_binary / dart_test are not among them, so hand-written
// targets (e.g. srcs=[] aggregator libraries) survive regeneration. Those
// kinds are removed only by the checks that recognise a target as Gazelle's
// to remove (`helperTests`, stale libraries, lib_dir.go, hook.go).
// `# keep` remains the escape hatch for hand-written codegen rules.
func deletableKinds(builders []*builderInfo) map[string]bool {
	m := map[string]bool{
		"dart_codegen":           true,
		"dart_aggregate_codegen": true,
		"dart_sqlcodegen":        true,
	}
	for _, k := range macroKinds(builders) {
		m[k] = true
	}
	return m
}

// staleCodegenRules returns empty-rule markers for every existing rule of
// a deletable kind whose name was not regenerated this pass, or was
// regenerated as another kind: a source whose annotations changed moves
// between macros, or between a macro and a codegen chain. Gazelle's merger
// deletes the matching rules from the BUILD file.
func staleCodegenRules(f *rule.File, gen []*rule.Rule, deletable map[string]bool) []*rule.Rule {
	if f == nil {
		return nil
	}
	generated := make(map[string]string, len(gen))
	for _, r := range gen {
		generated[r.Name()] = r.Kind()
	}
	var empty []*rule.Rule
	for _, existing := range f.Rules {
		if kind, ok := generated[existing.Name()]; (ok && kind == existing.Kind()) || !deletable[existing.Kind()] {
			continue
		}
		empty = append(empty, rule.NewRule(existing.Kind(), existing.Name()))
	}
	return empty
}

// libraryName determines the dart_library target name: the package name
// stated for the package (`statedPackageName`), else the name of the package
// root's directory, as `dart_library` derives it.
func libraryName(rel string, c *config.Config) string {
	if name := statedPackageName(c, rel); name != "" {
		return name
	}
	if p := placeDir(rel); p.Err == nil && p.Root != "" {
		return path.Base(p.Root)
	}
	if rel == "" || rel == "lib" {
		return "lib"
	}
	return path.Base(rel)
}

func fileNames(files []DartFileInfo) []string {
	names := make([]string, len(files))
	for i, f := range files {
		names[i] = f.Path
	}
	return names
}

// importSet is what a rule's files import: the packages they name, and the
// `package:` URI of each file imported by one, relative imports included, so
// a dep can resolve to the rule that holds the file.
type importSet struct {
	packages map[string]bool
	uris     map[string]map[string]bool // package name -> imported file URIs
	labels   []string                   // deps the rule takes whatever it imports

	// For a macro: the runtime package its annotation_dep names, and the
	// macro's default for it ("" when a directive states the dep).
	annotationPackage, annotationDefault string

	// For a codegen rule of a member of a cycle: the cycle, whose members
	// its generator reads (cycle.go).
	cycle *cycleDecl
}

// repoFiles is files, named relative to directory rel, named from the
// repository root.
func repoFiles(rel string, files []DartFileInfo) []DartFileInfo {
	out := make([]DartFileInfo, len(files))
	for i, f := range files {
		out[i] = f.at(path.Join(rel, f.Path))
	}
	return out
}

// collectRepoImports is what files, named from the repository root, of the
// package args.Rel is in import. A part directive adds nothing: the part is in
// the library, and its own imports are its file's.
func collectRepoImports(args language.GenerateArgs, files []DartFileInfo) *importSet {
	root, rootErr := packageRootOf(args.Config, args.Rel)
	self := packageNameIn(args.Config, args.Rel)
	is := &importSet{
		packages: make(map[string]bool),
		uris:     make(map[string]map[string]bool),
	}
	for _, f := range files {
		file := f.Path
		for _, imp := range f.Imports {
			if imp.IsPart {
				continue
			}
			uri := ""
			if rootErr == nil {
				uri = importedURI(self, root, file, imp)
			}
			if uri == "" {
				if imp.IsPackage {
					is.packages[imp.Package] = true
				}
				continue
			}
			pkg := strings.SplitN(strings.TrimPrefix(uri, "package:"), "/", 2)[0]
			is.packages[pkg] = true
			if is.uris[pkg] == nil {
				is.uris[pkg] = make(map[string]bool)
			}
			is.uris[pkg][uri] = true
		}
	}
	return is
}

// SortedURIs returns the file URIs imported from pkg, sorted.
func (is *importSet) SortedURIs(pkg string) []string {
	var uris []string
	for u := range is.uris[pkg] {
		uris = append(uris, u)
	}
	sort.Strings(uris)
	return uris
}

func (is *importSet) SortedPackages() []string {
	var pkgs []string
	for p := range is.packages {
		pkgs = append(pkgs, p)
	}
	sort.Strings(pkgs)
	return pkgs
}

func HasDartFiles(files []string) bool {
	for _, f := range files {
		if filepath.Ext(f) == ".dart" {
			return true
		}
	}
	return false
}
