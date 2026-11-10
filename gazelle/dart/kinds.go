package dart

import "github.com/bazelbuild/bazel-gazelle/rule"

// macroKindInfo is the common KindInfo for every per-builder convenience
// macro (e.g. `json_serializable_library`). All share the same srcs/deps
// shape, so Gazelle treats them uniformly.
var macroKindInfo = rule.KindInfo{
	MatchAttrs:    []string{"srcs"},
	NonEmptyAttrs: map[string]bool{"srcs": true},
	MergeableAttrs: map[string]bool{
		"srcs":             true,
		"deps":             true,
		"package_name":     true,
		"language_version": true,
		"package":          true,
		"annotation_dep":   true,
		"config":           true,
	},
	ResolveAttrs: map[string]bool{"deps": true},
}

// macroKinds lists every convenience-macro rule kind Gazelle may emit.
// Each entry MUST have a backing builderInfo in defaultBuilders(). The six
// stacked sub-builders are listed because `@StackedApp` drives five of
// them (router/locator/dialog/bottomsheet/logger) simultaneously; the
// sixth (`stacked_form_library`) covers `@FormView` independently.
var macroKinds = []string{
	"json_serializable_library",
	"freezed_library",
	"built_value_library",
	"mockito_library",
	"go_router_library",
	"copy_with_library",
	"drift_library",
	"stacked_router_library",
	"stacked_locator_library",
	"stacked_logger_library",
	"stacked_dialog_library",
	"stacked_bottomsheet_library",
	"stacked_form_library",
}

var dartKinds = func() map[string]rule.KindInfo {
	m := map[string]rule.KindInfo{}
	for _, k := range macroKinds {
		m[k] = macroKindInfo
	}
	for k, v := range _primitiveDartKinds {
		m[k] = v
	}
	return m
}()

var _primitiveDartKinds = map[string]rule.KindInfo{
	"dart_library": {
		MatchAttrs:    []string{"srcs"},
		NonEmptyAttrs: map[string]bool{"srcs": true},
		MergeableAttrs: map[string]bool{
			"srcs":             true,
			"deps":             true,
			"package_name":     true,
			"language_version": true,
			"package":          true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	"dart_binary": {
		MatchAttrs:    []string{"main"},
		NonEmptyAttrs: map[string]bool{"main": true},
		MergeableAttrs: map[string]bool{
			"srcs": true,
			"deps": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	"dart_test": {
		MatchAttrs:    []string{"main"},
		NonEmptyAttrs: map[string]bool{"main": true},
		// tags is Gazelle-managed: it holds the file's package:test @Tags, so
		// a tag removed from the source leaves the target. A tag written by
		// hand stays only with `# keep`, as for any managed attribute. main
		// is too, so a test made of a helper can be deleted (helperTests).
		MergeableAttrs: map[string]bool{
			"main": true,
			"srcs": true,
			"deps": true,
			"tags": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	// One per analysis_options.yaml, and the root's list of them. The config
	// matches by name alone: there is one per repository.
	"dart_analysis_options": {
		MatchAttrs:     []string{"src"},
		NonEmptyAttrs:  map[string]bool{"src": true},
		MergeableAttrs: map[string]bool{"src": true, "deps": true},
		ResolveAttrs:   map[string]bool{"deps": true},
	},
	// Never "empty": an empty config is valid (SDK defaults) and `.bazelrc`
	// files name it, so Gazelle must not delete it.
	"dart_analysis_config": {
		MergeableAttrs: map[string]bool{"options": true},
	},
	// Code-gen primitives. Emitted by Gazelle's DAG-synthesis when
	// annotations are detected; also usable by hand.
	"dart_codegen": {
		MatchAttrs:    []string{"src", "generator_bin"},
		NonEmptyAttrs: map[string]bool{"src": true},
		MergeableAttrs: map[string]bool{
			"src":              true,
			"generator_bin":    true,
			"output_suffixes":  true,
			"deps":             true,
			"asset_deps":       true,
			"parts":            true,
			"config":           true,
			"data":             true,
			"generator_args":   true,
			"package_name":     true,
			"language_version": true,
			"package":          true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	"dart_aggregate_codegen": {
		MatchAttrs:    []string{"srcs", "generator_bin"},
		NonEmptyAttrs: map[string]bool{"srcs": true},
		MergeableAttrs: map[string]bool{
			"srcs":             true,
			"generator_bin":    true,
			"outputs":          true,
			"deps":             true,
			"generator_args":   true,
			"package_name":     true,
			"language_version": true,
			"package":          true,
		},
	},
	"dart_sqlcodegen": {
		MatchAttrs:    []string{"src", "generator_bin"},
		NonEmptyAttrs: map[string]bool{"src": true},
		MergeableAttrs: map[string]bool{
			"src":              true,
			"generator_bin":    true,
			"output_suffixes":  true,
			"deps":             true,
			"data":             true,
			"generator_args":   true,
			"package_name":     true,
			"language_version": true,
			"package":          true,
		},
	},
}
