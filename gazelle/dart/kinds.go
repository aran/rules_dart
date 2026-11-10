package dart

import "github.com/bazelbuild/bazel-gazelle/rule"

// macroKindInfo is the common KindInfo for every per-builder convenience
// macro (e.g. `json_serializable_codegen`), which writes a builder's codegen
// targets for its sources and names their outputs for a library's `srcs`.
// All share the same srcs/deps shape, so Gazelle treats them uniformly.
var macroKindInfo = rule.KindInfo{
	MatchAttrs:    []string{"srcs"},
	NonEmptyAttrs: map[string]bool{"srcs": true},
	MergeableAttrs: map[string]bool{
		"srcs":           true,
		"deps":           true,
		"asset_deps":     true,
		"package":        true,
		"annotation_dep": true,
		"config":         true,
	},
	ResolveAttrs: map[string]bool{"deps": true},
}

// macroKinds lists every convenience-macro rule kind Gazelle may emit.
// Each entry MUST have a backing builderInfo in defaultBuilders(). The six
// stacked sub-builders are listed because `@StackedApp` drives five of
// them (router/locator/dialog/bottomsheet/logger) simultaneously; the
// sixth (`stacked_form_codegen`) covers `@FormView` independently.
var macroKinds = []string{
	"json_serializable_codegen",
	"freezed_codegen",
	"built_value_codegen",
	"mockito_codegen",
	"go_router_codegen",
	"copy_with_codegen",
	"drift_codegen",
	"stacked_router_codegen",
	"stacked_locator_codegen",
	"stacked_logger_codegen",
	"stacked_dialog_codegen",
	"stacked_bottomsheet_codegen",
	"stacked_form_codegen",
}

// removedFactAttrs are the package facts a rule of the package stated
// inline before `dart_package_metadata` held them all. Gazelle manages them
// on every kind it writes for a package, so that rewriting a BUILD file
// removes them: it writes none (metadata.go). A library's `code_assets`
// moves onto the package's metadata (`moveCodeAssets`).
var removedFactAttrs = []string{
	"package_name", "language_version", "build_hook", "link_hook", "license_file",
}

var dartKinds = func() map[string]rule.KindInfo {
	m := map[string]rule.KindInfo{}
	for _, k := range macroKinds {
		m[k] = withRemovedFacts(macroKindInfo)
	}
	for k, v := range _primitiveDartKinds {
		switch k {
		case "filegroup", "dart_package_metadata", "dart_analysis_options", "dart_analysis_config":
		default:
			v = withRemovedFacts(v)
		}
		m[k] = v
	}
	return m
}()

// withRemovedFacts is k managing removedFactAttrs too.
func withRemovedFacts(k rule.KindInfo) rule.KindInfo {
	merge := map[string]bool{}
	for a := range k.MergeableAttrs {
		merge[a] = true
	}
	for _, a := range removedFactAttrs {
		merge[a] = true
	}
	k.MergeableAttrs = merge
	return k
}

var _primitiveDartKinds = map[string]rule.KindInfo{
	// The helpers a test-tree directory lends the tests of others
	// (package_scan.go), and a package's hooks (hook.go).
	"filegroup": {
		NonEmptyAttrs:  map[string]bool{"srcs": true},
		MergeableAttrs: map[string]bool{"srcs": true, "visibility": true},
	},
	// A package's facts (metadata.go). Gazelle writes all but
	// `code_assets` and `version`, which it keeps: only a person states
	// them. A hook or license file gone from the package leaves it.
	"dart_package_metadata": {
		NonEmptyAttrs: map[string]bool{"package_name": true},
		MergeableAttrs: map[string]bool{
			"package_name":     true,
			"language_version": true,
			"build_hook":       true,
			"link_hook":        true,
			"license_file":     true,
		},
	},
	"dart_library": {
		MatchAttrs:    []string{"srcs"},
		NonEmptyAttrs: map[string]bool{"srcs": true},
		// code_assets, which `dart_library` no longer takes, moves onto the
		// package's metadata (`moveCodeAssets`).
		MergeableAttrs: map[string]bool{
			"srcs":        true,
			"deps":        true,
			"package":     true,
			"code_assets": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	"dart_binary": {
		MatchAttrs:    []string{"main"},
		NonEmptyAttrs: map[string]bool{"main": true},
		MergeableAttrs: map[string]bool{
			"srcs":    true,
			"deps":    true,
			"package": true,
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
		// target_compatible_with, which holds the platforms of the file's
		// @TestOn, is managed too, but by test_on.go: Gazelle's merger
		// merges no select but rules_go's.
		MergeableAttrs: map[string]bool{
			"main":    true,
			"srcs":    true,
			"deps":    true,
			"tags":    true,
			"package": true,
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
			"src":             true,
			"generator_bin":   true,
			"output_suffixes": true,
			"deps":            true,
			"asset_deps":      true,
			"parts":           true,
			"config":          true,
			"data":            true,
			"generator_args":  true,
			"package":         true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
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
			"package":        true,
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
			"package":         true,
		},
	},
}
