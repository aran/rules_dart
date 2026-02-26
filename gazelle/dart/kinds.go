package dart

import "github.com/bazelbuild/bazel-gazelle/rule"

var dartKinds = map[string]rule.KindInfo{
	"dart_library": {
		MatchAttrs:    []string{"srcs"},
		NonEmptyAttrs: map[string]bool{"srcs": true},
		MergeableAttrs: map[string]bool{
			"srcs":         true,
			"deps":         true,
			"package_name": true,
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
}
