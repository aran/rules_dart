package dart

import (
	"log"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// builderInfo describes one entry in the builder registry — i.e. one
// `package:build` Builder we know how to wire into a generated BUILD file.
//
// Fields mirror build_runner's `build.yaml`. Mandatory fields are
// `Annotation`, `ShimLabel`, `Macro`, and `Produces`.
type builderInfo struct {
	// Annotation is the case-sensitive annotation name (e.g. "JsonSerializable")
	// that identifies a Dart source as needing this builder.
	Annotation string

	// ShimLabel is the absolute label of the per-builder shim binary
	// (e.g. "@rules_dart//dart/ext/json_serializable:shim"). Used as
	// `generator_bin` on the emitted dart_codegen / dart_aggregate_codegen.
	ShimLabel string

	// Macro is the loadable symbol for the convenience macro Gazelle emits
	// for single-annotation files (e.g.
	// "@rules_dart//dart/ext/json_serializable:defs.bzl%json_serializable_library").
	Macro string

	// Produces is the list of file extensions emitted (e.g. [".g.dart"] or
	// [".json_serializable.g.part"]). The first extension is the primary
	// output that downstream consumers wire up.
	Produces []string

	// Consumes is the list of input file extensions (typically [".dart"]).
	// Used to build the per-file DAG.
	Consumes []string

	// RunsBefore is a list of annotation names this builder must run before
	// (e.g. freezed runs before json_serializable). Adds explicit DAG edges.
	RunsBefore []string

	// SharedPart means the builder emits a `.<name>.g.part` SharedPart shard
	// that needs the combining-shim stage to merge into a final `.g.dart`.
	SharedPart bool

	// Aggregate means the builder is a PackageBuilder; emits one
	// dart_aggregate_codegen target rather than a per-file dart_codegen.
	Aggregate bool

	// RuntimeDep is the runtime dart_library label to add to the consumer's
	// `dart_library.deps` (set via `dart_builder_runtime_dep` directive).
	RuntimeDep string

	// Config is a JSON string of builder options (set via
	// `dart_builder_config` directive).
	Config string
}

// clone returns a shallow copy of this builderInfo. Slice fields are
// reallocated so subsequent mutation on the copy doesn't alias the
// original.
func (b *builderInfo) clone() *builderInfo {
	out := *b
	if b.Produces != nil {
		out.Produces = append([]string(nil), b.Produces...)
	}
	if b.Consumes != nil {
		out.Consumes = append([]string(nil), b.Consumes...)
	}
	if b.RunsBefore != nil {
		out.RunsBefore = append([]string(nil), b.RunsBefore...)
	}
	return &out
}

// builderRegistry maps annotation name → list of builderInfos that watch
// that annotation. Most annotations have one entry; a few (notably
// `@StackedApp`) have several (one per sub-builder the annotation drives).
//
// The registry is held on the Gazelle config under `extKeyBuilderRegistry`.
// Because Gazelle shallow-copies `c.Exts` on directory entry, the
// *builderRegistry pointer is shared between parent and child configs; we
// deep-clone on first access per config so per-directory overrides from
// `dart_builder_runtime_dep` / `dart_builder_config` directives don't bleed
// between siblings.
type builderRegistry struct {
	byAnnotation map[string][]*builderInfo
}

const extKeyBuilderRegistry = "dart_builder_registry"

// builderRegistryOf returns the registry stored on c. If one is already
// present (populated by an ancestor's `Configure` call), it is deep-cloned
// so per-directory `dart_builder_runtime_dep` / `dart_builder_config`
// overrides don't leak across siblings that share the ancestor's pointer
// via Gazelle's shallow `c.Exts` copy.
//
// If no registry is present, a fresh one is created and pre-populated with
// the rules_dart-shipped defaults.
func builderRegistryOf(c *config.Config) *builderRegistry {
	if c.Exts == nil {
		c.Exts = map[string]interface{}{}
	}
	if existing, ok := c.Exts[extKeyBuilderRegistry].(*builderRegistry); ok {
		clone := &builderRegistry{
			byAnnotation: make(map[string][]*builderInfo, len(existing.byAnnotation)),
		}
		for ann, infos := range existing.byAnnotation {
			cloned := make([]*builderInfo, 0, len(infos))
			for _, info := range infos {
				cloned = append(cloned, info.clone())
			}
			clone.byAnnotation[ann] = cloned
		}
		c.Exts[extKeyBuilderRegistry] = clone
		return clone
	}
	r := &builderRegistry{byAnnotation: map[string][]*builderInfo{}}
	for _, info := range defaultBuilders() {
		r.byAnnotation[info.Annotation] = append(
			r.byAnnotation[info.Annotation],
			info.clone(),
		)
	}
	c.Exts[extKeyBuilderRegistry] = r
	return r
}

// defaultBuilders returns the rules_dart-shipped registrations for the
// bundled `dart/ext/<builder>` shims. Most annotations register exactly
// one builderInfo; `@StackedApp` registers five (one per stacked
// sub-builder that watches it).
//
// Keep this list aligned with `dart/ext/`'s subdirectories.
func defaultBuilders() []*builderInfo {
	return []*builderInfo{
		{
			Annotation: "JsonSerializable",
			ShimLabel:  "@rules_dart//dart/ext/json_serializable:shim",
			Macro:      "@rules_dart//dart/ext/json_serializable:defs.bzl%json_serializable_library",
			Produces:   []string{".json_serializable.g.part"},
			Consumes:   []string{".dart"},
			SharedPart: true,
			RuntimeDep: "@pub_deps//:json_annotation",
		},
		{
			// Synthetic trigger: idiomatic built_value classes carry no
			// annotation; ParseDartCodegenTriggers emits "BuiltValue" when
			// a class implements `Built<T, B>`. The explicit @BuiltValue
			// annotation maps here too.
			Annotation: "BuiltValue",
			ShimLabel:  "@rules_dart//dart/ext/built_value:shim",
			Macro:      "@rules_dart//dart/ext/built_value:defs.bzl%built_value_library",
			Produces:   []string{".built_value.g.part"},
			Consumes:   []string{".dart"},
			SharedPart: true,
			RuntimeDep: "@pub_deps//:built_value",
		},
		{
			// `@SerializersFor([...])` drives built_value_generator's
			// serializer aggregation (see the e2e exemplar's
			// serializers.dart); same builder as BuiltValue.
			Annotation: "SerializersFor",
			ShimLabel:  "@rules_dart//dart/ext/built_value:shim",
			Macro:      "@rules_dart//dart/ext/built_value:defs.bzl%built_value_library",
			Produces:   []string{".built_value.g.part"},
			Consumes:   []string{".dart"},
			SharedPart: true,
			RuntimeDep: "@pub_deps//:built_value",
		},
		{
			// `@freezed` (instance form) and `@Freezed(...)` (class form)
			// both map to this registration — the parser-time lookup
			// canonicalizes the lowercase form to `Freezed` before
			// registry lookup (see canonicalAnnotationName).
			Annotation: "Freezed",
			ShimLabel:  "@rules_dart//dart/ext/freezed:shim",
			Macro:      "@rules_dart//dart/ext/freezed:defs.bzl%freezed_library",
			Produces:   []string{".freezed.dart"},
			Consumes:   []string{".dart"},
			RunsBefore: []string{"JsonSerializable"},
			RuntimeDep: "@pub_deps//:freezed_annotation",
		},
		{
			Annotation: "CopyWith",
			ShimLabel:  "@rules_dart//dart/ext/copy_with_extension_gen:shim",
			Macro:      "@rules_dart//dart/ext/copy_with_extension_gen:defs.bzl%copy_with_library",
			Produces:   []string{".copy_with_extension_gen.g.part"},
			Consumes:   []string{".dart"},
			SharedPart: true,
			RuntimeDep: "@pub_deps//:copy_with_extension",
		},
		{
			Annotation: "GenerateMocks",
			ShimLabel:  "@rules_dart//dart/ext/mockito:shim",
			Macro:      "@rules_dart//dart/ext/mockito:defs.bzl%mockito_library",
			Produces:   []string{".mocks.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:mockito",
		},
		{
			Annotation: "TypedGoRoute",
			ShimLabel:  "@rules_dart//dart/ext/go_router:shim",
			Macro:      "@rules_dart//dart/ext/go_router:defs.bzl%go_router_library",
			Produces:   []string{".go_router.g.part"},
			Consumes:   []string{".dart"},
			SharedPart: true,
			RuntimeDep: "@pub_deps//:go_router",
		},
		{
			Annotation: "InjectableInit",
			ShimLabel:  "@rules_dart//dart/ext/injectable:shim_config",
			Macro:      "@rules_dart//dart/ext/injectable:defs.bzl%injectable_library",
			// injectable_config_builder emits both `.config.dart` and
			// `.module.dart` per init source. Both are declared so
			// Gazelle can filter generated sources consistently.
			Produces:   []string{".config.dart", ".module.dart"},
			Consumes:   []string{".dart"},
			Aggregate:  true,
			RuntimeDep: "@pub_deps//:injectable",
		},
		{
			Annotation: "DriftDatabase",
			ShimLabel:  "@rules_dart//dart/ext/drift:shim_drift",
			Macro:      "@rules_dart//dart/ext/drift:defs.bzl%drift_library",
			Produces:   []string{".drift.g.part"},
			Consumes:   []string{".dart"},
			SharedPart: true,
			RuntimeDep: "@pub_deps//:drift",
		},
		// Stacked's `@StackedApp` drives five of the six sub-builders
		// simultaneously; each emits its own `.<slot>.dart` library. The
		// sixth (`.form.dart`) has a distinct annotation and is registered
		// separately below.
		{
			Annotation: "StackedApp",
			ShimLabel:  "@rules_dart//dart/ext/stacked:shim_router",
			Macro:      "@rules_dart//dart/ext/stacked:defs.bzl%stacked_router_library",
			Produces:   []string{".router.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:stacked",
		},
		{
			Annotation: "StackedApp",
			ShimLabel:  "@rules_dart//dart/ext/stacked:shim_locator",
			Macro:      "@rules_dart//dart/ext/stacked:defs.bzl%stacked_locator_library",
			Produces:   []string{".locator.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:stacked",
		},
		{
			Annotation: "StackedApp",
			ShimLabel:  "@rules_dart//dart/ext/stacked:shim_logger",
			Macro:      "@rules_dart//dart/ext/stacked:defs.bzl%stacked_logger_library",
			Produces:   []string{".logger.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:stacked",
		},
		{
			Annotation: "StackedApp",
			ShimLabel:  "@rules_dart//dart/ext/stacked:shim_dialog",
			Macro:      "@rules_dart//dart/ext/stacked:defs.bzl%stacked_dialog_library",
			Produces:   []string{".dialogs.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:stacked",
		},
		{
			Annotation: "StackedApp",
			ShimLabel:  "@rules_dart//dart/ext/stacked:shim_bottomsheet",
			Macro:      "@rules_dart//dart/ext/stacked:defs.bzl%stacked_bottomsheet_library",
			Produces:   []string{".bottomsheets.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:stacked",
		},
		{
			Annotation: "FormView",
			ShimLabel:  "@rules_dart//dart/ext/stacked:shim_form",
			Macro:      "@rules_dart//dart/ext/stacked:defs.bzl%stacked_form_library",
			Produces:   []string{".form.dart"},
			Consumes:   []string{".dart"},
			RuntimeDep: "@pub_deps//:stacked",
		},
	}
}

// configureBuilderDirectives merges `dart_builder_runtime_dep` and
// `dart_builder_config` directives from f into the registry on c. These
// directives configure *built-in* builders; they do not register new ones.
//
// Idempotent within a directory: re-declaring an annotation overwrites the
// prior directive value. Applies to every registered builderInfo for the
// named annotation (relevant for `@StackedApp` with its five registrations).
func configureBuilderDirectives(c *config.Config, f *rule.File) {
	if f == nil {
		return
	}
	r := builderRegistryOf(c)
	for _, d := range f.Directives {
		switch d.Key {
		case "dart_builder_runtime_dep":
			ann, dep, ok := splitTwo(d.Value)
			if !ok {
				log.Printf("dart: dart_builder_runtime_dep: expected "+
					"`<Annotation> <label>`, got %q", d.Value)
				continue
			}
			for _, info := range r.byAnnotation[ann] {
				info.RuntimeDep = dep
			}
		case "dart_builder_config":
			ann, cfg, ok := splitTwo(d.Value)
			if !ok {
				log.Printf("dart: dart_builder_config: expected "+
					"`<Annotation> <json>`, got %q", d.Value)
				continue
			}
			for _, info := range r.byAnnotation[ann] {
				info.Config = cfg
			}
		}
	}
}

// allRegisteredProducedExtensions returns every output extension declared
// by every registered builder, sorted lexicographically for deterministic
// callers. Used by generate.go to suppress generating rules for files
// whose names look like codegen outputs.
func (r *builderRegistry) allRegisteredProducedExtensions() []string {
	seen := map[string]struct{}{}
	var out []string
	for _, infos := range r.byAnnotation {
		for _, b := range infos {
			for _, ext := range b.Produces {
				if _, ok := seen[ext]; !ok {
					seen[ext] = struct{}{}
					out = append(out, ext)
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

// lookup returns every builderInfo that watches `annotation`. Most
// annotations have one entry; `@StackedApp` has five.
//
// Canonicalises `@freezed` (instance) → `Freezed` (class) before lookup so
// both annotation forms resolve to the same registration.
func (r *builderRegistry) lookup(annotation string) []*builderInfo {
	if r == nil {
		return nil
	}
	if infos, ok := r.byAnnotation[annotation]; ok {
		return infos
	}
	if canon := canonicalAnnotationName(annotation); canon != annotation {
		return r.byAnnotation[canon]
	}
	return nil
}

// canonicalAnnotationName maps an annotation's instance form (lowercase
// first letter — e.g. `freezed`, a top-level const instance of the
// `Freezed` class) to its class form. Dart convention: classes are
// PascalCase, const instances are camelCase. A single registration under
// the class name covers both.
func canonicalAnnotationName(name string) string {
	if name == "" {
		return name
	}
	first, size := utf8.DecodeRuneInString(name)
	if !unicode.IsLower(first) {
		return name
	}
	return string(unicode.ToUpper(first)) + name[size:]
}

func splitTwo(s string) (string, string, bool) {
	parts := strings.Fields(s)
	if len(parts) < 2 {
		return "", "", false
	}
	return parts[0], strings.Join(parts[1:], " "), true
}
