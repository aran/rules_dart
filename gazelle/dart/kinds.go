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
	"injectable_library",
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
		MergeableAttrs: map[string]bool{
			"srcs": true,
			"deps": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	// Code-gen primitives. Emitted by Gazelle's DAG-synthesis when
	// annotations are detected; also usable by hand.
	"dart_codegen": {
		MatchAttrs:    []string{"src", "generator_bin"},
		NonEmptyAttrs: map[string]bool{"src": true},
		MergeableAttrs: map[string]bool{
			"src":             true,
			"generator_bin":   true,
			"output_suffixes": true,
			"deps":            true,
			"data":            true,
			"generator_args":  true,
		},
	},
	"dart_aggregate_codegen": {
		MatchAttrs:    []string{"srcs", "generator_bin"},
		NonEmptyAttrs: map[string]bool{"srcs": true},
		MergeableAttrs: map[string]bool{
			"srcs":           true,
			"generator_bin":  true,
			"outputs":        true,
			"deps":           true,
			"generator_args": true,
		},
	},
	"dart_sqlcodegen": {
		MatchAttrs:    []string{"src", "generator_bin"},
		NonEmptyAttrs: map[string]bool{"src": true},
		MergeableAttrs: map[string]bool{
			"src":             true,
			"generator_bin":   true,
			"output_suffixes": true,
			"deps":            true,
			"data":            true,
			"generator_args":  true,
		},
	},
}
