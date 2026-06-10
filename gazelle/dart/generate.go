package dart

import (
	_ "embed"
	"log"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

//go:embed baseline_generated_extensions.txt
var baselineGeneratedExtensionsRaw string

// baselineGeneratedExtensions is the full well-known set of Dart codegen
// output extensions. When `.g.dart` arrives as a combining-shim output
// (not produced by any individual Builder registration) it still needs to
// be filtered; same for common build_runner extensions users may have
// committed during migration.
var baselineGeneratedExtensions = func() []string {
	var out []string
	for _, line := range strings.Split(baselineGeneratedExtensionsRaw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	return out
}()

// injectableInitAnnotation is the marker annotation identifying the file
// that drives the injectable config stage. Scanning for it at the
// directory level lets Gazelle emit a single `injectable_library` macro
// covering every annotated file in the directory.
const injectableInitAnnotation = "InjectableInit"

// GenerateRules generates Dart BUILD rules for a directory.
func (d *dartLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	dartFiles, err := ParseDartDir(args.Dir, args.RegularFiles)
	if err != nil || len(dartFiles) == 0 {
		return language.GenerateResult{}
	}

	registry, _ := args.Config.Exts[extKeyBuilderRegistry].(*builderRegistry)

	// Drop generated files from the file list — they're outputs of
	// codegen rules, not inputs we should emit dart_library / dart_binary
	// rules for. Detected by suffix match against any registered
	// `produces=` extension.
	dartFiles = filterOutGeneratedFiles(dartFiles, registry)

	// Classify files by conventional directory.
	var libFiles, binFiles, testFiles []DartFileInfo
	for _, f := range dartFiles {
		switch {
		case isInDir(args.Rel, "test") || strings.HasSuffix(f.Path, "_test.dart"):
			testFiles = append(testFiles, f)
		case isInDir(args.Rel, "bin"):
			binFiles = append(binFiles, f)
		default:
			libFiles = append(libFiles, f)
		}
	}

	// Discover annotated lib-level sources. Every file that carries a
	// registered annotation participates in codegen emission; everything
	// else falls through to the plain dart_library path below.
	annotatedFiles := map[string][]string{}
	injectableInitFiles := []string{}
	for _, f := range libFiles {
		annPath := filepath.Join(args.Dir, f.Path)
		anns, err := ParseDartCodegenTriggers(annPath)
		if err != nil {
			log.Printf("dart: %s: annotation parse failed: %v", annPath, err)
			continue
		}
		if len(anns) == 0 {
			continue
		}
		var registered []string
		registeredSeen := map[string]struct{}{}
		for _, a := range anns {
			if _, ok := registeredSeen[a]; ok {
				continue
			}
			if registry.lookup(a) != nil {
				registeredSeen[a] = struct{}{}
				registered = append(registered, a)
			}
		}
		if len(registered) > 0 {
			annotatedFiles[f.Path] = registered
		}
		for _, a := range anns {
			if a == injectableInitAnnotation {
				injectableInitFiles = append(injectableInitFiles, f.Path)
				break
			}
		}
	}

	var gen []*rule.Rule
	var imports []interface{}

	// Handle the injectable aggregate case specially: one macro call per
	// directory, not per file. This stays closest to build_runner's
	// auto_apply behavior (all files with injectable-family annotations
	// run through the metadata stage; the single @InjectableInit file
	// drives the config stage).
	injectableConsumed := map[string]bool{}
	if len(injectableInitFiles) > 0 {
		if len(injectableInitFiles) > 1 {
			log.Printf("dart: %s: more than one @InjectableInit file "+
				"found (%v); emitting injectable_library for the first only",
				args.Rel, injectableInitFiles)
		}
		initSrc := injectableInitFiles[0]
		rule := buildInjectableMacro(args, libFiles, initSrc)
		gen = append(gen, rule)
		imports = append(imports, collectImports(libFiles))
		for _, f := range libFiles {
			injectableConsumed[f.Path] = true
		}
	}

	// Emit codegen per annotated source that wasn't consumed by the
	// injectable aggregate above.
	for _, f := range libFiles {
		if injectableConsumed[f.Path] {
			continue
		}
		anns, ok := annotatedFiles[f.Path]
		if !ok {
			continue
		}
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
		// matching non-aggregate builder, and that builder has a `Macro`.
		// This produces a single `<builder>_library(...)` call. Aggregate
		// builders (`@InjectableInit`) are always handled out-of-band
		// above, so they don't hit this path.
		if len(anns) == 1 && len(flatBuilders) == 1 &&
			flatBuilders[0].Macro != "" && !flatBuilders[0].Aggregate {
			macroRule := buildMacroRule(args, f, flatBuilders[0])
			if macroRule != nil {
				gen = append(gen, macroRule)
				imports = append(imports, collectImports([]DartFileInfo{f}))
				continue
			}
		}

		stages, err := buildPipelineForFile(anns, registry)
		if err != nil {
			log.Printf("dart: %s: %v", f.Path, err)
			continue
		}
		emitted, libSrcs := emitCodegenStages(args, f, stages)
		gen = append(gen, emitted...)
		for range emitted {
			imports = append(imports, nil)
		}
		libRule := buildAnnotatedLibrary(args, f, libSrcs)
		gen = append(gen, libRule)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	// Plain dart_library for unannotated lib/ sources (the common case).
	plain := []DartFileInfo{}
	for _, f := range libFiles {
		if injectableConsumed[f.Path] {
			continue
		}
		if _, ok := annotatedFiles[f.Path]; !ok {
			plain = append(plain, f)
		}
	}
	if len(plain) > 0 {
		r := rule.NewRule("dart_library", libraryName(args.Rel, args.Dir, args.Config))
		srcs := fileNames(plain)
		sort.Strings(srcs)
		r.SetAttr("srcs", srcs)
		r.SetAttr("visibility", []string{"//visibility:public"})
		needsPkgName := false
		if args.Config.Exts != nil {
			if _, ok := args.Config.Exts["dart_package_name"].(string); ok {
				needsPkgName = true
			}
		}
		if FindPubspecName(args.Dir, args.Rel) != "" {
			needsPkgName = true
		}
		if needsPkgName {
			r.SetAttr("package_name", r.Name())
		}
		gen = append(gen, r)
		imports = append(imports, collectImports(plain))
	}

	for _, f := range binFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_binary", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	for _, f := range testFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_test", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	return language.GenerateResult{
		Gen:     gen,
		Imports: imports,
	}
}

// filterOutGeneratedFiles drops every file whose name ends in any
// registered `produces=` extension. Without this, Gazelle would emit a
// dart_library for `foo.g.dart` (a generated file) instead of treating it
// as the output of the codegen rule.
func filterOutGeneratedFiles(files []DartFileInfo, registry *builderRegistry) []DartFileInfo {
	if registry == nil || len(registry.byAnnotation) == 0 {
		return files
	}
	prods := registry.allRegisteredProducedExtensions()
	prods = append(prods, baselineGeneratedExtensions...)
	// Allocate a fresh backing array; `files[:0]` would alias the caller's
	// slice and mutate its tail — latent trap if callers ever rely on the
	// input's elements past the filtered length.
	out := make([]DartFileInfo, 0, len(files))
outer:
	for _, f := range files {
		for _, ext := range prods {
			if strings.HasSuffix(f.Path, ext) {
				continue outer
			}
		}
		out = append(out, f)
	}
	return out
}

// stageTargetName returns the synthetic Bazel target name for a stage of
// the codegen pipeline applied to one source file. Single-registration
// annotations use `_<base>_<ann_slug>_gen`; fan-out annotations
// (`@StackedApp` → 5 builders) get a discriminator from the primary
// extension's leading segment (`router`, `locator`, …) to keep target
// names unique within the pipeline.
func stageTargetName(srcPath string, stage pipelineStage, fanOut bool) string {
	base := strings.TrimSuffix(filepath.Base(srcPath), ".dart")
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

	for _, stage := range stages {
		fanOut := stage.Builder != nil &&
			annotationCount[stage.Builder.Annotation] > 1
		name := stageTargetName(f.Path, stage, fanOut)
		byID[stage.ID] = name
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
		} else if stage.Builder.Aggregate {
			// Aggregate stages come from the directory-level injectable
			// emission path; a per-file Aggregate in the DAG is unusual
			// but supported — one declared Bazel output per suffix.
			outputs := make([]string, 0, len(stage.OutputExts))
			stem := strings.TrimSuffix(f.Path, ".dart")
			for _, ext := range stage.OutputExts {
				outputs = append(outputs, stem+ext)
			}
			r = rule.NewRule("dart_aggregate_codegen", name)
			r.SetAttr("srcs", []string{f.Path})
			r.SetAttr("generator_bin", stage.Builder.ShimLabel)
			r.SetAttr("outputs", outputs)
		} else {
			r = rule.NewRule("dart_codegen", name)
			r.SetAttr("src", f.Path)
			r.SetAttr("generator_bin", stage.Builder.ShimLabel)
			r.SetAttr("output_suffixes", stage.OutputExts)
			if stage.Builder.RuntimeDep != "" {
				r.SetAttr("deps", []string{stage.Builder.RuntimeDep})
			}
			if stage.Builder.Config != "" {
				r.SetAttr("config", stage.Builder.Config)
			}
		}
		if pkgName := libraryName(args.Rel, args.Dir, args.Config); pkgName != "" {
			r.SetAttr("package_name", pkgName)
		}
		if lv := resolvedLanguageVersion(args); lv != "" {
			r.SetAttr("language_version", lv)
		}
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
	name := strings.TrimSuffix(filepath.Base(f.Path), ".dart")
	r := rule.NewRule(kind, name)
	r.SetAttr("srcs", []string{f.Path})
	r.SetAttr("visibility", []string{"//visibility:public"})
	pkgName := libraryName(args.Rel, args.Dir, args.Config)
	r.SetAttr("package_name", pkgName)
	if lv := resolvedLanguageVersion(args); lv != "" {
		r.SetAttr("language_version", lv)
	}
	if info.Config != "" {
		r.SetAttr("config", info.Config)
	}
	return r
}

// buildInjectableMacro emits the single `injectable_library(...)` call
// covering every file in the directory. `srcs` is the full set of
// non-generated lib/ files so the metadata stage processes every potential
// `@injectable`/`@singleton`/`@module` site; `init_src` is the detected
// `@InjectableInit` file.
func buildInjectableMacro(
	args language.GenerateArgs,
	libFiles []DartFileInfo,
	initSrc string,
) *rule.Rule {
	name := libraryName(args.Rel, args.Dir, args.Config)
	r := rule.NewRule("injectable_library", name)
	srcs := fileNames(libFiles)
	sort.Strings(srcs)
	r.SetAttr("srcs", srcs)
	r.SetAttr("init_src", initSrc)
	r.SetAttr("visibility", []string{"//visibility:public"})
	r.SetAttr("package_name", name)
	if lv := resolvedLanguageVersion(args); lv != "" {
		r.SetAttr("language_version", lv)
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
	libName := strings.TrimSuffix(filepath.Base(f.Path), ".dart")
	r := rule.NewRule("dart_library", libName)
	srcs := append([]string{f.Path}, genTargets...)
	r.SetAttr("srcs", srcs)
	r.SetAttr("visibility", []string{"//visibility:public"})
	if FindPubspecName(args.Dir, args.Rel) != "" ||
		(args.Config.Exts != nil && args.Config.Exts["dart_package_name"] != nil) {
		r.SetAttr("package_name", libraryName(args.Rel, args.Dir, args.Config))
	}
	if lv := resolvedLanguageVersion(args); lv != "" {
		r.SetAttr("language_version", lv)
	}
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

// resolvedLanguageVersion returns the language_version to propagate onto
// emitted codegen rules / macros. The per-directory
// `# gazelle:dart_language_version` directive takes precedence; otherwise
// Gazelle derives it from the nearest `pubspec.yaml`'s
// `environment.sdk` constraint.
func resolvedLanguageVersion(args language.GenerateArgs) string {
	if args.Config.Exts != nil {
		if lv, ok := args.Config.Exts["dart_language_version"].(string); ok && lv != "" {
			return lv
		}
	}
	return FindPubspecLanguageVersion(args.Dir, args.Rel)
}

// libraryName determines the dart_library target name.
func libraryName(rel string, dir string, c *config.Config) string {
	if c.Exts != nil {
		if name, ok := c.Exts["dart_package_name"].(string); ok && name != "" {
			return name
		}
	}
	if name := FindPubspecName(dir, rel); name != "" {
		return name
	}
	if rel == "" {
		return "lib"
	}
	return path.Base(rel)
}

func isInDir(rel string, dir string) bool {
	return rel == dir || strings.HasPrefix(rel, dir+"/")
}

func fileNames(files []DartFileInfo) []string {
	names := make([]string, len(files))
	for i, f := range files {
		names[i] = f.Path
	}
	return names
}

type importSet struct {
	packages map[string]bool
}

func collectImports(files []DartFileInfo) *importSet {
	is := &importSet{packages: make(map[string]bool)}
	for _, f := range files {
		for _, imp := range f.Imports {
			if imp.IsPackage {
				is.packages[imp.Package] = true
			}
		}
	}
	return is
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
