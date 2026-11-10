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
// then the analysis options targets (analysis_options.go).
func (d *dartLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	res := d.generateDartRules(args)
	taken := map[string]bool{}
	for _, r := range res.Gen {
		taken[r.Name()] = true
	}
	gen, imports, empty := d.analysisRules(args, taken)
	res.Gen = append(res.Gen, gen...)
	res.Imports = append(res.Imports, imports...)
	res.Empty = append(res.Empty, empty...)
	return res
}

func (d *dartLang) generateDartRules(args language.GenerateArgs) language.GenerateResult {
	if layout, root := layoutOf(args.Rel); layout == "hook" {
		return hookRules(args, root)
	}
	place := placeDir(args.Rel)
	if place.Err == nil && (place.Split || args.Rel == libDirOf(place.Root)) {
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

	// The library of the package rooted here, when it has a lib/.
	var gen []*rule.Rule
	var imports []interface{}
	ownsLib := hasFile(args.Subdirs, "lib") && !hasLibComponent(args.Rel)
	if ownsLib {
		gen, imports = d.packageLibraryRules(args)
	}
	if len(dartFiles) == 0 && len(gen) == 0 {
		return language.GenerateResult{}
	}
	d.checkAgreement(args)

	// Classify files by the conventional directory of their package.
	layout, _ := layoutOf(args.Rel)
	var libFiles, binFiles, testFiles []DartFileInfo
	helpers := map[string]DartFileInfo{}
	for _, f := range dartFiles {
		switch {
		case strings.HasSuffix(f.Path, "_test.dart"):
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
		scripts, scriptImports, old := d.scriptRules(args, libFiles, gen)
		gen = append(gen, scripts...)
		imports = append(imports, scriptImports...)
		stale = old
	}

	// A test-tree directory another directory imports from holds what it
	// lends (package_scan.go).
	if layout == "test" {
		_, root := layoutOf(args.Rel)
		scan := d.scan.scanOf(args.Config, root)
		if lent := scan.lent[args.Rel]; len(lent) > 0 {
			gen = append(gen, sourcesFilegroup(args.Rel, lent,
				label.New("", path.Join(root, "test"), "__subpackages__").String()))
			imports = append(imports, nil)
		}
	}

	for _, f := range binFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_binary", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports(args, []DartFileInfo{f}))
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
		gen = append(gen, r)
		imports = append(imports, collectRepoImports(args, files))
	}

	empty := append(staleCodegenRules(args.File, gen), helperTests(args.File, helpers)...)
	empty = append(empty, stale...)
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
// `dart_library`, holding every source under lib/ that carries no
// registered annotation, and for each source that carries one, its codegen
// targets and the library holding it and what they generate
// (package_scan.go).
func (d *dartLang) packageLibraryRules(args language.GenerateArgs) ([]*rule.Rule, []interface{}) {
	root := args.Rel
	scan := d.scan.scanOf(args.Config, root)
	if len(scan.lib) == 0 {
		return nil, nil
	}
	registry, _ := args.Config.Exts[extKeyBuilderRegistry].(*builderRegistry)
	if len(scan.annotated) > 0 {
		// The options the package's build.yaml states for the builders.
		registry = d.withBuildYaml(args, registry)
	}
	pkgLib := libraryName(root, args.Config)

	var gen []*rule.Rule
	var imports []interface{}
	var plain []DartFileInfo
	for _, file := range scan.lib {
		if _, ok := scan.annotated[file.Path]; !ok {
			plain = append(plain, file)
		}
	}
	for _, file := range scan.lib {
		f := DartFileInfo{Path: relTo(root, file.Path), Imports: file.Imports}
		anns, ok := scan.annotated[file.Path]
		if !ok {
			continue
		}
		if stem := libStem(f.Path); stem == pkgLib && len(plain) > 0 {
			d.errs.add(fmt.Sprintf(
				"dart: %s: its library, which holds what its annotations generate, "+
					"would be named %q, as the package's own library is; rename the file",
				file.Path, stem))
			continue
		}
		rules, is := d.codegenRules(args, f, anns, registry)
		gen = append(gen, rules...)
		imports = append(imports, is...)
	}
	if len(plain) == 0 {
		logUnstatedHooks(root)
		return gen, imports
	}

	r := rule.NewRule("dart_library", pkgLib)
	// The name is stated only where something states it; unstated,
	// dart_library derives the same one from the target's name.
	name := ""
	if statedPackageName(args.Config, root) != "" {
		name = r.Name()
	}
	setPackageIdentity(r, args, name)
	srcs := make([]string, len(plain))
	for i, f := range plain {
		srcs[i] = relTo(root, f.Path)
	}
	r.SetAttr("srcs", srcs)
	// The package's hooks, on its library (hook.go).
	files := append(append([]DartFileInfo(nil), plain...), setHooks(r, args.Config.RepoRoot, root, args.Rel)...)
	r.SetAttr("visibility", []string{"//visibility:public"})
	gen = append(gen, r)
	imports = append(imports, collectRepoImports(args, files))
	return gen, imports
}

// scriptRules is what Gazelle writes for the Dart files of a directory in
// no package's lib/, bin/ or test/ (tool/, example/), which are scripts: a
// `dart_binary` for each file with a top-level `main`, holding in `srcs`
// each file of the directory it reaches by relative imports. A file no
// binary reaches is an error naming it, since nothing could build it. A
// `dart_library` of the directory's own files, which earlier Gazelle
// versions wrote and `dart_library` refuses outside lib/, is deleted.
func (d *dartLang) scriptRules(args language.GenerateArgs, files []DartFileInfo, taken []*rule.Rule) ([]*rule.Rule, []interface{}, []*rule.Rule) {
	byPath := map[string]DartFileInfo{}
	for _, f := range repoFiles(args.Rel, files) {
		byPath[f.Path] = f
	}
	reached := map[string]bool{}
	var gen []*rule.Rule
	var imports []interface{}
	for _, f := range files {
		if !HasTopLevelMain(filepath.Join(args.Dir, f.Path)) {
			continue
		}
		main := byPath[path.Join(args.Rel, f.Path)]
		reached[main.Path] = true
		held := []DartFileInfo{main}
		var srcs []string
		var visit func(DartFileInfo)
		visit = func(g DartFileInfo) {
			for _, imp := range g.Imports {
				h, ok := byPath[relativeTarget(g.Path, imp)]
				if !ok || h.Path == main.Path || containsFile(held, h.Path) {
					continue
				}
				reached[h.Path] = true
				held = append(held, h)
				srcs = append(srcs, path.Base(h.Path))
				visit(h)
			}
		}
		visit(main)
		name := strings.TrimSuffix(f.Path, ".dart")
		if ruleNamed(taken, name) != nil {
			d.errs.add(fmt.Sprintf(
				"dart: %s: its `dart_binary` would be named %q, as the package's "+
					"library is; rename the file", main.Path, name))
			continue
		}
		r := rule.NewRule("dart_binary", name)
		r.SetAttr("main", f.Path)
		if len(srcs) > 0 {
			sort.Strings(srcs)
			r.SetAttr("srcs", srcs)
		}
		gen = append(gen, r)
		imports = append(imports, collectRepoImports(args, held))
	}
	for _, f := range sortedKeys(byPath) {
		if !reached[f] {
			d.errs.add(fmt.Sprintf(
				"dart: %s is in no package's lib/, bin/ or test/, has no top-level "+
					"`main`, and no script beside it imports it; move it into lib/ or "+
					"beside the script that uses it, or exclude it with `# gazelle:exclude`",
				f))
		}
	}
	var stale []*rule.Rule
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "dart_library" && !r.ShouldKeep() && ownSources(r, args.RegularFiles) {
				stale = append(stale, rule.NewRule("dart_library", r.Name()))
			}
		}
	}
	return gen, imports, stale
}

func containsFile(files []DartFileInfo, p string) bool {
	for _, f := range files {
		if f.Path == p {
			return true
		}
	}
	return false
}

// codegenRules is what Gazelle writes for a source under lib/ carrying the
// registered annotations anns, f named from the package's root: a macro
// when one builder, with a macro, serves its one annotation, else the
// codegen chain of its builders and the `dart_library` holding the source
// and what the chain generates.
func (d *dartLang) codegenRules(args language.GenerateArgs, f DartFileInfo, anns []string, registry *builderRegistry) ([]*rule.Rule, []interface{}) {
	// Resolve every annotation to its registered builders. A single
	// annotation may fan out to multiple builders (e.g. `@StackedApp`
	// drives five sub-builders). Preserve the order in `anns` so the
	// DAG has deterministic input even before topological sort.
	var flatBuilders []*builderInfo
	flatSeen := map[string]struct{}{}
	for _, a := range anns {
		for _, info := range registry.lookup(a) {
			key := nodeKey(info)
			if _, ok := flatSeen[key]; ok {
				continue
			}
			flatSeen[key] = struct{}{}
			flatBuilders = append(flatBuilders, info)
		}
	}

	// Fast-path macro emission: exactly one annotation, exactly one
	// matching builder, and that builder has a `Macro`. This produces a
	// single `<builder>_library(...)` call.
	if len(anns) == 1 && len(flatBuilders) == 1 && flatBuilders[0].Macro != "" {
		if macroRule := buildMacroRule(args, f, flatBuilders[0]); macroRule != nil {
			is := collectImports(args, []DartFileInfo{f})
			if b := flatBuilders[0]; b.RuntimeDep == defaultRuntimeDeps[nodeKey(b)] {
				is.annotationPackage = runtimePackage(b)
				is.annotationDefault = b.RuntimeDep
			}
			return []*rule.Rule{macroRule}, []interface{}{is}
		}
	}

	stages, err := buildPipelineForFile(anns, registry)
	if err != nil {
		log.Printf("dart: %s: %v", path.Join(args.Rel, f.Path), err)
		return nil, nil
	}
	gen, libSrcs := emitCodegenStages(args, f, stages)
	// A generator resolves the source, so each stage depends on what
	// the source imports, and on its builder's runtime library.
	var imports []interface{}
	for i := range gen {
		if stages[i].Combining {
			imports = append(imports, nil)
			continue
		}
		is := collectImports(args, []DartFileInfo{f})
		if b := stages[i].Builder; b.RuntimeDep != defaultRuntimeDeps[nodeKey(b)] {
			is.labels = append(is.labels, b.RuntimeDep)
		} else if pkg := runtimePackage(b); pkg != "" {
			is.packages[pkg] = true
		}
		imports = append(imports, is)
	}
	gen = append(gen, buildAnnotatedLibrary(args, f, libSrcs))
	imports = append(imports, collectImports(args, []DartFileInfo{f}))
	return gen, imports
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

// hasLibComponent reports whether a directory is inside some `lib/`, or is
// one.
func hasLibComponent(rel string) bool {
	for _, p := range strings.Split(rel, "/") {
		if p == "lib" {
			return true
		}
	}
	return false
}

func ruleNamed(rules []*rule.Rule, name string) *rule.Rule {
	for _, r := range rules {
		if r.Name() == name {
			return r
		}
	}
	return nil
}

// testHelpers is what a test reaches through relative imports, its own or
// those of the files it reaches: the `srcs` of its dart_test, sorted -- each
// file of its own directory, and the filegroup of each other test-tree
// directory of its package it reaches a file of (package_scan.go) -- and
// every file those hold, the test first, repo-relative. A relative import of
// a file in another directory that no rule holds is logged.
func (d *dartLang) testHelpers(args language.GenerateArgs, test DartFileInfo) ([]string, []DartFileInfo) {
	_, root := layoutOf(args.Rel)
	scan := d.scan.scanOf(args.Config, root)
	self := packageNameIn(args.Config, args.Rel)
	main := DartFileInfo{Path: path.Join(args.Rel, test.Path), Imports: test.Imports}
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
			case ok:
				if !seen["//"+dir] {
					seen["//"+dir] = true
					lent = append(lent, dirLabel(dir, args.Rel))
					for _, h := range scan.lent[dir] {
						add(h)
					}
				}
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

// helperTests returns empty-rule markers for each existing dart_test whose
// main is a helper: a file package:test never runs, made a test by earlier
// Gazelle versions. `# keep` keeps one written by hand.
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
// dart_library / dart_binary / dart_test are NEVER deleted so hand-written
// targets (e.g. srcs=[] aggregator libraries) survive regeneration.
// `# keep` remains the escape hatch for hand-written codegen rules.
var deletableKinds = func() map[string]bool {
	m := map[string]bool{
		"dart_codegen":           true,
		"dart_aggregate_codegen": true,
		"dart_sqlcodegen":        true,
	}
	for _, k := range macroKinds {
		m[k] = true
	}
	return m
}()

// staleCodegenRules returns empty-rule markers for every existing rule of
// a deletable kind whose name was not regenerated this pass, and for every
// existing library a rule of another library kind now takes the name of: a
// source that gained or lost an annotation moves between a macro and a
// codegen chain's `dart_library`, both named for the source. Gazelle's merger
// deletes the matching rules from the BUILD file.
func staleCodegenRules(f *rule.File, gen []*rule.Rule) []*rule.Rule {
	if f == nil {
		return nil
	}
	generated := make(map[string]string, len(gen))
	for _, r := range gen {
		generated[r.Name()] = r.Kind()
	}
	var empty []*rule.Rule
	for _, existing := range f.Rules {
		kind, ok := generated[existing.Name()]
		switch {
		case ok && kind != existing.Kind() && libraryKinds[kind] && libraryKinds[existing.Kind()]:
		case !ok && deletableKinds[existing.Kind()]:
		default:
			continue
		}
		empty = append(empty, rule.NewRule(existing.Kind(), existing.Name()))
	}
	return empty
}

// libraryKinds are the kinds of the library Gazelle writes for a source:
// dart_library and every convenience macro.
var libraryKinds = func() map[string]bool {
	m := map[string]bool{"dart_library": true}
	for _, k := range macroKinds {
		m[k] = true
	}
	return m
}()

// stageTargetName returns the synthetic Bazel target name for a stage of
// the codegen pipeline applied to one source file. Single-registration
// annotations use `_<base>_<ann_slug>_gen`; fan-out annotations
// (`@StackedApp` → 5 builders) get a discriminator from the primary
// extension's leading segment (`router`, `locator`, …) to keep target
// names unique within the pipeline.
func stageTargetName(srcPath string, stage pipelineStage, fanOut bool) string {
	base := libStem(srcPath)
	if stage.Combining {
		return "_" + base + "_combined"
	}
	ann := lowerSnake(stage.Builder.Annotation)
	if !fanOut {
		return "_" + base + "_" + ann + "_gen"
	}
	// Use the primary-extension's first non-empty segment as the
	// discriminator — `.router.dart` → `router`, `.locator.dart` →
	// `locator`. Falls back to the full slug when no clean segment exists.
	primary := ""
	if len(stage.Builder.Produces) > 0 {
		primary = stage.Builder.Produces[0]
	}
	discriminator := primarySegment(primary)
	if discriminator == "" {
		discriminator = strings.Trim(strings.ReplaceAll(primary, ".", "_"), "_")
	}
	return "_" + base + "_" + ann + "_" + discriminator + "_gen"
}

// primarySegment extracts the first non-empty `.`-delimited segment of an
// extension like `.router.dart` → `router`. Returns `""` when there is no
// content between dots.
func primarySegment(ext string) string {
	trimmed := strings.TrimPrefix(ext, ".")
	parts := strings.SplitN(trimmed, ".", 2)
	if len(parts) == 0 {
		return ""
	}
	return parts[0]
}

// emitCodegenStages emits one rule per pipeline stage and returns the
// emitted rules plus the labels that should appear in the wrapping
// `dart_library`'s srcs list.
func emitCodegenStages(
	args language.GenerateArgs,
	f DartFileInfo,
	stages []pipelineStage,
) ([]*rule.Rule, []string) {
	_ = args
	var rules []*rule.Rule
	var labels []string
	byID := map[string]string{}

	// Precompute which annotations have multiple stages in this pipeline
	// — i.e. fan-outs like `@StackedApp`. Only those need the extension
	// discriminator appended to their target name.
	annotationCount := map[string]int{}
	for _, s := range stages {
		if s.Builder != nil {
			annotationCount[s.Builder.Annotation]++
		}
	}

	builderOf := map[string]*builderInfo{}
	for _, stage := range stages {
		fanOut := stage.Builder != nil &&
			annotationCount[stage.Builder.Annotation] > 1
		name := stageTargetName(f.Path, stage, fanOut)
		byID[stage.ID] = name
		builderOf[stage.ID] = stage.Builder
		var r *rule.Rule
		if stage.Combining {
			r = rule.NewRule("dart_codegen", name)
			r.SetAttr("src", f.Path)
			r.SetAttr("generator_bin",
				"@rules_dart//dart/ext/_shared/combining_shim:bin")
			r.SetAttr("output_suffixes", stage.OutputExts)
			parts := make([]string, 0, len(stage.PartShards))
			for _, shardID := range stage.PartShards {
				if tgt, ok := byID[shardID]; ok {
					parts = append(parts, ":"+tgt)
				}
			}
			r.SetAttr("parts", parts)
		} else {
			r = rule.NewRule("dart_codegen", name)
			r.SetAttr("src", f.Path)
			r.SetAttr("generator_bin", stage.Builder.ShimLabel)
			r.SetAttr("output_suffixes", stage.OutputExts)
			// What an earlier builder wrote into the source's library (a
			// `.freezed.dart` part), this one reads as a staged file: no
			// library can hold the source before this stage's output exists.
			// A SharedPart shard is not a part of the library, so it is
			// left to the combining stage.
			var assets []string
			for _, id := range stage.After {
				if b := builderOf[id]; b != nil && !b.SharedPart {
					assets = append(assets, ":"+byID[id])
				}
			}
			if len(assets) > 0 {
				r.SetAttr("asset_deps", assets)
			}
			if stage.Builder.Config != "" {
				r.SetAttr("config", stage.Builder.Config)
			}
		}
		setPackageIdentity(r, args, packageNameIn(args.Config, args.Rel))
		rules = append(rules, r)
		labels = append(labels, ":"+name)
	}

	// The wrapping library needs every stage's output that isn't a
	// SharedPart shard (SharedPart shards are merged into the combining
	// stage's `.g.dart`, which stands in for them). For pipelines without
	// any combining stage, every stage's output goes in.
	var libSrcs []string
	hasCombining := false
	for _, s := range stages {
		if s.Combining {
			hasCombining = true
			break
		}
	}
	for i, s := range stages {
		if hasCombining && s.Builder != nil && s.Builder.SharedPart {
			continue
		}
		libSrcs = append(libSrcs, labels[i])
	}
	return rules, libSrcs
}

// macroRuleKind strips the macro symbol from a `<label>:<defs.bzl>%<macro>`
// form — returning just the macro symbol (which becomes the rule kind).
func macroRuleKind(macro string) string {
	pct := strings.LastIndex(macro, "%")
	if pct < 0 {
		return ""
	}
	return macro[pct+1:]
}

// defaultRuntimeDeps maps each shipped builder registration (keyed by
// nodeKey) to its default RuntimeDep, which tells a
// `dart_builder_runtime_dep` directive's label from the default: a
// directive's label is used as stated, the default is resolved as an import
// of its package (runtimePackage) and stated on a macro only where that
// differs from the macro's own default.
var defaultRuntimeDeps = func() map[string]string {
	m := map[string]string{}
	for _, b := range defaultBuilders() {
		m[nodeKey(b)] = b.RuntimeDep
	}
	return m
}()

// runtimePackage is the Dart package of a builder's default runtime
// library (`json_annotation` for `@pub_deps//:json_annotation`), which
// Gazelle resolves as it resolves an import of that package; "" when the
// builder has none.
func runtimePackage(b *builderInfo) string {
	dep := defaultRuntimeDeps[nodeKey(b)]
	if i := strings.LastIndex(dep, ":"); i >= 0 {
		return dep[i+1:]
	}
	return ""
}

// buildMacroRule emits a single `<builder>_library(...)` rule call for a
// one-annotation source. Returns nil if the builder's `Macro` field is
// malformed.
func buildMacroRule(
	args language.GenerateArgs,
	f DartFileInfo,
	info *builderInfo,
) *rule.Rule {
	kind := macroRuleKind(info.Macro)
	if kind == "" {
		return nil
	}
	name := libStem(f.Path)
	r := rule.NewRule(kind, name)
	r.SetAttr("srcs", []string{f.Path})
	r.SetAttr("visibility", []string{"//visibility:public"})
	setPackageIdentity(r, args, packageNameIn(args.Config, args.Rel))
	if info.RuntimeDep != "" && info.RuntimeDep != defaultRuntimeDeps[nodeKey(info)] {
		r.SetAttr("annotation_dep", info.RuntimeDep)
	}
	if info.Config != "" {
		r.SetAttr("config", info.Config)
	}
	return r
}

// buildAnnotatedLibrary emits the dart_library wrapping an annotated
// source plus every generated output that belongs in the user's library.
func buildAnnotatedLibrary(
	args language.GenerateArgs,
	f DartFileInfo,
	genTargets []string,
) *rule.Rule {
	libName := libStem(f.Path)
	r := rule.NewRule("dart_library", libName)
	srcs := append([]string{f.Path}, genTargets...)
	r.SetAttr("srcs", srcs)
	r.SetAttr("visibility", []string{"//visibility:public"})

	// Unconditionally, and from the same libraryName() the dart_codegen rules
	// above used. Emitting it only when a pubspec or directive named the
	// package left dart_library to fall back to its label, which agrees with
	// libraryName() everywhere except the workspace root: there libraryName()
	// yields "lib" while the label yields the target's own name, so the
	// generated sources were produced for one package and collected into
	// another. dart_library's fallback is still correct for a library Gazelle
	// emits with no codegen beside it; it is only wrong next to a rule that
	// already committed to a name.
	setPackageIdentity(r, args, packageNameIn(args.Config, args.Rel))
	return r
}

// lowerSnake naively snake-cases an annotation name (CamelCase →
// camel_case). Only used for synthetic target names; readability matters
// more than correctness on non-ASCII.
func lowerSnake(s string) string {
	var b strings.Builder
	for i, r := range s {
		if r >= 'A' && r <= 'Z' {
			if i > 0 {
				b.WriteByte('_')
			}
			b.WriteRune(r + 32)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// setPackageIdentity states the Dart package a generated rule belongs to,
// either by reference to the directory's `dart_package_metadata` or inline:
// pkgName, when not "", and the language version, when one is stated. Every
// rule Gazelle writes for a package's lib/ states it so, the generated and the
// plain alike, since a version stated once applies to all of them.
func setPackageIdentity(r *rule.Rule, args language.GenerateArgs, pkgName string) {
	if decl := packageDeclFor(args); decl != "" {
		r.SetAttr("package", decl)
		return
	}
	if pkgName != "" {
		r.SetAttr("package_name", pkgName)
	}
	if lv := resolvedLanguageVersion(args); lv != "" {
		r.SetAttr("language_version", lv)
	}
}

// resolvedLanguageVersion returns the language_version to propagate onto
// emitted codegen rules / macros: the `# gazelle:dart_language_version`
// directive's, or else the one the pubspec.yaml at the package's root derives
// from its `environment.sdk` constraint. `checkAgreement` has made sure the
// two do not disagree.
func resolvedLanguageVersion(args language.GenerateArgs) string {
	if f := directiveFact(args.Config, keyLanguageVersion); f != nil {
		return f.Value
	}
	if root, err := packageRootOf(args.Rel); err == nil {
		_, lv := pubspecFacts(args.Config, root)
		return lv
	}
	return ""
}

// statedPackageName is the package name a `dart_package_metadata`, a
// directive or the pubspec.yaml at the package's root states for a
// directory, or "" when none does. `checkAgreement` has made sure they do not
// disagree.
func statedPackageName(c *config.Config, rel string) string {
	if d := packageDeclIn(c, rel); d != nil {
		return d.PackageName
	}
	if f := directiveFact(c, keyPackageName); f != nil {
		return f.Value
	}
	if root, err := packageRootOf(rel); err == nil {
		name, _ := pubspecFacts(c, root)
		return name
	}
	return ""
}

// libraryName determines the dart_library target name: the package name a
// directive or pubspec states, else the name of the package root's
// directory, as `dart_library` derives it.
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
}

func collectImports(args language.GenerateArgs, files []DartFileInfo) *importSet {
	return collectRepoImports(args, repoFiles(args.Rel, files))
}

// repoFiles is files, named relative to directory rel, named from the
// repository root.
func repoFiles(rel string, files []DartFileInfo) []DartFileInfo {
	out := make([]DartFileInfo, len(files))
	for i, f := range files {
		out[i] = DartFileInfo{Path: path.Join(rel, f.Path), Imports: f.Imports}
	}
	return out
}

// collectRepoImports is what files, named from the repository root, of the
// package args.Rel is in import.
func collectRepoImports(args language.GenerateArgs, files []DartFileInfo) *importSet {
	root, rootErr := packageRootOf(args.Rel)
	self := packageNameIn(args.Config, args.Rel)
	is := &importSet{
		packages: make(map[string]bool),
		uris:     make(map[string]map[string]bool),
	}
	for _, f := range files {
		file := f.Path
		for _, imp := range f.Imports {
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
