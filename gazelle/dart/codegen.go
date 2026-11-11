package dart

import (
	"log"
	"path"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// What Gazelle writes for the sources under a package's lib/ that carry
// registered annotations. build_runner writes a `.g.dart` or similar beside
// its source, as a part of the source's library, so the outputs of each
// source's codegen targets are in the `srcs` of the package's one
// `dart_library` (package_scan.go), beside the source. A source that one
// builder with a macro serves gets that macro (`json_serializable_codegen`),
// named for the source's path under lib/ and `_codegen`; any other gets the
// chain of its builders' `dart_codegen` targets (dag.go).
//
// The package's library holds what a generator writes, so no generator can
// depend on it. A generator sees instead, as staged files (`asset_deps`), the
// files of the package its source reaches by imports, with what builders that
// run before its own (build_runner's earlier phases) write for them, and
// depends (`deps`) on the libraries of the other packages those files import.

// codegenPlan is how Gazelle generates what one annotated source's builders
// write.
type codegenPlan struct {
	// file is the source, named from the package's root.
	file DartFileInfo
	// macro is the source's one builder, when it has a macro; stages is
	// the chain of its builders otherwise.
	macro  *builderInfo
	stages []pipelineStage
	// names holds the target name of each stage, by stage ID.
	names map[string]string
}

// planCodegen is how Gazelle generates what the builders of the source f,
// carrying the registered annotations anns, write.
func planCodegen(f DartFileInfo, anns []string, registry *builderRegistry) (*codegenPlan, error) {
	p := &codegenPlan{file: f}
	if b := soleBuilder(anns, registry); b != nil && macroRuleKind(b.Macro) != "" {
		p.macro = b
		return p, nil
	}
	stages, err := buildPipelineForFile(anns, registry)
	if err != nil {
		return nil, err
	}
	// A fan-out annotation (`@StackedApp`) needs the extension in each of
	// its stages' names to keep them apart.
	perAnnotation := map[string]int{}
	for _, s := range stages {
		if s.Builder != nil {
			perAnnotation[s.Builder.Annotation]++
		}
	}
	p.stages = stages
	p.names = map[string]string{}
	for _, s := range stages {
		fanOut := s.Builder != nil && perAnnotation[s.Builder.Annotation] > 1
		p.names[s.ID] = stageTargetName(f.Path, s, fanOut)
	}
	return p, nil
}

// soleBuilder is the one builder serving anns, the source's only annotation,
// or nil when there are more.
func soleBuilder(anns []string, registry *builderRegistry) *builderInfo {
	if len(anns) != 1 {
		return nil
	}
	if bs := registry.lookup(anns[0]); len(bs) == 1 {
		return bs[0]
	}
	return nil
}

// builders is every builder the plan runs.
func (p *codegenPlan) builders() []*builderInfo {
	if p.macro != nil {
		return []*builderInfo{p.macro}
	}
	var out []*builderInfo
	for _, s := range p.stages {
		if s.Builder != nil {
			out = append(out, s.Builder)
		}
	}
	return out
}

// macroName is the name of the macro Gazelle writes for a source under lib/,
// named from the package's root.
func macroName(file string) string {
	return libStem(file) + "_codegen"
}

// outputOf is the label of the target holding what builder b writes into
// the library for the plan's source, "" when the plan does not run b or b
// writes a SharedPart shard, which only the combining stage reads.
func (p *codegenPlan) outputOf(b *builderInfo) string {
	if b.SharedPart {
		return ""
	}
	if p.macro != nil {
		if nodeKey(p.macro) == nodeKey(b) {
			return ":" + macroName(p.file.Path)
		}
		return ""
	}
	if name, ok := p.names[nodeKey(b)]; ok {
		return ":" + name
	}
	return ""
}

// librarySrcs is the labels of what the plan generates into the library:
// the macro, or every stage but the SharedPart shards, which the combining
// stage's `.g.dart` stands in for.
func (p *codegenPlan) librarySrcs() []string {
	if p.macro != nil {
		return []string{":" + macroName(p.file.Path)}
	}
	var out []string
	for _, s := range p.stages {
		if s.Builder == nil || !s.Builder.SharedPart {
			out = append(out, ":"+p.names[s.ID])
		}
	}
	return out
}

// codegenRules is what Gazelle writes for the annotated sources of the
// package scanned, rooted at args.Rel: each source's macro or chain, with
// their imports, the labels of what they generate into the package's
// library, and the builders they run, whose runtime libraries the library
// depends on.
func (d *dartLang) codegenRules(args language.GenerateArgs, scan *packageScan, registry *builderRegistry) ([]*rule.Rule, []interface{}, []string, []*builderInfo) {
	root := args.Rel
	plans := map[string]*codegenPlan{} // repo-relative source -> plan
	for _, file := range scan.lib {
		anns, ok := scan.annotated[file.Path]
		if !ok {
			continue
		}
		p, err := planCodegen(DartFileInfo{Path: relTo(root, file.Path), Imports: file.Imports}, anns, registry)
		if err != nil {
			log.Printf("dart: %s: %v", file.Path, err)
			continue
		}
		plans[file.Path] = p
	}
	reach := packageReach(scan.lib, packageNameIn(args.Config, root), root)
	pkg := ""
	if m := d.metadataOf(args.Config, root); m != nil {
		pkg = m.labelFrom(args.Rel)
	}

	var gen []*rule.Rule
	var imports []interface{}
	var srcs []string
	var runtime []*builderInfo
	for _, file := range scan.lib {
		p, ok := plans[file.Path]
		if !ok {
			continue
		}
		reached := reach(file.Path)
		// What a builder sees of the package: the files the source reaches,
		// and what earlier builders write for them.
		visible := func(b *builderInfo) []string {
			var out []string
			for _, r := range reached {
				out = append(out, relTo(root, r.Path))
			}
			for _, r := range reached {
				q, ok := plans[r.Path]
				if !ok {
					continue
				}
				for _, e := range q.builders() {
					if lbl := q.outputOf(e); lbl != "" && registry.runsBefore(e, b) {
						out = append(out, lbl)
					}
				}
			}
			return out
		}
		files := append([]DartFileInfo{file}, reached...)
		rules, is := emitCodegen(args, pkg, p, files, visible)
		gen = append(gen, rules...)
		imports = append(imports, is...)
		srcs = append(srcs, p.librarySrcs()...)
		runtime = append(runtime, p.builders()...)
	}
	return gen, imports, srcs, runtime
}

// packageReach returns, for a source in lib, the package's sources in lib,
// repo-relative and sorted, that the source reaches through imports of its
// own package, itself left out.
func packageReach(lib []DartFileInfo, self, root string) func(file string) []DartFileInfo {
	byPath := map[string]DartFileInfo{}
	for _, f := range lib {
		byPath[f.Path] = f
	}
	prefix := "package:" + self + "/"
	return func(file string) []DartFileInfo {
		seen := map[string]bool{file: true}
		var out []DartFileInfo
		var visit func(f DartFileInfo)
		visit = func(f DartFileInfo) {
			for _, imp := range f.Imports {
				uri := importedURI(self, root, f.Path, imp)
				if !strings.HasPrefix(uri, prefix) {
					continue
				}
				g, ok := byPath[path.Join(libDirOf(root), strings.TrimPrefix(uri, prefix))]
				if !ok || seen[g.Path] {
					continue
				}
				seen[g.Path] = true
				out = append(out, g)
				visit(g)
			}
		}
		visit(byPath[file])
		sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
		return out
	}
}

// emitCodegen writes the plan's rules, each naming pkg, the package's
// metadata, when it has one, with each rule's imports: those of files, the
// source then what it reaches, repo-relative, less its own package's, which
// its rules see through visible.
func emitCodegen(args language.GenerateArgs, pkg string, p *codegenPlan, files []DartFileInfo, visible func(*builderInfo) []string) ([]*rule.Rule, []interface{}) {
	self := packageNameIn(args.Config, args.Rel)
	importsOf := func() *importSet {
		is := collectRepoImports(args, files)
		delete(is.packages, self)
		delete(is.uris, self)
		return is
	}
	if b := p.macro; b != nil {
		r := rule.NewRule(macroRuleKind(b.Macro), macroName(p.file.Path))
		r.SetAttr("srcs", []string{p.file.Path})
		if assets := visible(b); len(assets) > 0 {
			r.SetAttr("asset_deps", assets)
		}
		setPackage(r, pkg)
		if b.Config != "" {
			r.SetAttr("config", b.Config)
		}
		is := importsOf()
		if overridesRuntimeDep(b) {
			// The macro adds its annotation_dep to its deps, in place of
			// the default runtime package its source imports.
			r.SetAttr("annotation_dep", b.RuntimeDep)
			dropPackage(is, runtimePackage(b))
		} else {
			is.annotationPackage = runtimePackage(b)
			is.annotationDefault = b.RuntimeDep
		}
		return []*rule.Rule{r}, []interface{}{is}
	}

	var rules []*rule.Rule
	var imports []interface{}
	builderOf := map[string]*builderInfo{}
	for _, stage := range p.stages {
		builderOf[stage.ID] = stage.Builder
		r := rule.NewRule("dart_codegen", p.names[stage.ID])
		r.SetAttr("src", p.file.Path)
		r.SetAttr("output_suffixes", stage.OutputExts)
		if stage.Combining {
			r.SetAttr("generator", "@rules_dart//dart/ext/combining_shim:bin")
			parts := make([]string, 0, len(stage.PartShards))
			for _, id := range stage.PartShards {
				parts = append(parts, ":"+p.names[id])
			}
			r.SetAttr("parts", parts)
			setPackage(r, pkg)
			rules = append(rules, r)
			imports = append(imports, nil)
			continue
		}
		r.SetAttr("generator", stage.Builder.ShimLabel)
		// What an earlier builder wrote into the source's library (a
		// `.freezed.dart` part), this one reads as a staged file: no
		// library can hold the source before this stage's output exists.
		// A SharedPart shard is not a part of the library, so it is left to
		// the combining stage.
		var assets []string
		for _, id := range stage.After {
			if b := builderOf[id]; b != nil && !b.SharedPart {
				assets = append(assets, ":"+p.names[id])
			}
		}
		assets = append(assets, visible(stage.Builder)...)
		if len(assets) > 0 {
			r.SetAttr("asset_deps", assets)
		}
		if stage.Builder.Config != "" {
			r.SetAttr("config", stage.Builder.Config)
		}
		setPackage(r, pkg)
		rules = append(rules, r)
		// A generator resolves the source, so each stage depends on its
		// builder's runtime library too.
		is := importsOf()
		addRuntimeDeps(is, []*builderInfo{stage.Builder})
		imports = append(imports, is)
	}
	return rules, imports
}

// setPackage names pkg, the package's metadata, on r, when it has one.
func setPackage(r *rule.Rule, pkg string) {
	if pkg != "" {
		r.SetAttr("package", pkg)
	}
}

// addRuntimeDeps adds to is the runtime library of each of builders: the
// default as an import of its package, a directive's label as stated, in
// place of the default package, which the source may import too.
func addRuntimeDeps(is *importSet, builders []*builderInfo) {
	for _, b := range builders {
		if pkg := runtimePackage(b); !overridesRuntimeDep(b) && pkg != "" {
			is.packages[pkg] = true
		}
	}
	for _, b := range builders {
		if overridesRuntimeDep(b) {
			dropPackage(is, runtimePackage(b))
			is.labels = append(is.labels, b.RuntimeDep)
		}
	}
}

// overridesRuntimeDep reports whether a `dart_builder_runtime_dep`
// directive states builder b's runtime library.
func overridesRuntimeDep(b *builderInfo) bool {
	return b.RuntimeDep != "" && b.RuntimeDep != b.defaultRuntimeDep
}

// dropPackage removes package pkg from what is imports.
func dropPackage(is *importSet, pkg string) {
	delete(is.packages, pkg)
	delete(is.uris, pkg)
}

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

// macroRuleKind strips the macro symbol from a `<label>:<defs.bzl>%<macro>`
// form — returning just the macro symbol (which becomes the rule kind).
func macroRuleKind(macro string) string {
	pct := strings.LastIndex(macro, "%")
	if pct < 0 {
		return ""
	}
	return macro[pct+1:]
}

// macroFile is the `.bzl` file a `<file>%<symbol>` macro is loaded from.
func macroFile(macro string) string {
	pct := strings.LastIndex(macro, "%")
	if pct < 0 {
		return ""
	}
	return macro[:pct]
}

// runtimePackage is the Dart package of a builder's default runtime
// library (`json_annotation` for `@pub_deps//:json_annotation`), which
// Gazelle resolves as it resolves an import of that package; "" when the
// builder has none. The default tells a `dart_builder_runtime_dep`
// directive's label from it: a directive's label is used as stated, and
// stated on a macro, where the default is the macro's own.
func runtimePackage(b *builderInfo) string {
	dep := b.defaultRuntimeDep
	if i := strings.LastIndex(dep, ":"); i >= 0 {
		return dep[i+1:]
	}
	return ""
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
