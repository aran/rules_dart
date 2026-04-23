// Package dart implements a Gazelle language extension for Dart.
//
// It generates dart_library, dart_binary, and dart_test BUILD targets
// from Dart source files by parsing import statements and applying
// Dart package conventions.
package dart

import (
	"flag"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const dartName = "dart"

// dartLang implements language.Language for Dart.
type dartLang struct{}

// NewLanguage creates a new Dart language extension for Gazelle.
func NewLanguage() language.Language {
	return &dartLang{}
}

func (*dartLang) Name() string { return dartName }

func (*dartLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {}
func (*dartLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error           { return nil }

func (*dartLang) KnownDirectives() []string {
	return []string{
		"dart_package_name",
		"dart_pub_deps_repo",
		// Directives that tune *registered* (built-in) builders. Custom
		// builder registration is not supported via directive — hand-write
		// a `dart_codegen` target if you need one.
		"dart_builder_runtime_dep",
		"dart_builder_config",
		// Optional override of the `language_version` attr emitted on
		// generated `<builder>_library` macros. When unset, the rule layer
		// applies a safe default.
		"dart_language_version",
	}
}

func (*dartLang) Configure(c *config.Config, rel string, f *rule.File) {
	if f == nil {
		return
	}
	for _, d := range f.Directives {
		switch d.Key {
		case "dart_package_name":
			// Store custom package name override in config
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts["dart_package_name"] = d.Value
		case "dart_pub_deps_repo":
			// Store pub deps repository name for external dep labels
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts["dart_pub_deps_repo"] = d.Value
		case "dart_language_version":
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts["dart_language_version"] = d.Value
		}
	}
	// Merge dart_builder* directives into the per-config registry. Done
	// separately so dart_builder configuration is decoupled from the
	// existing single-line directives above.
	configureBuilderDirectives(c, f)
}

func (*dartLang) Kinds() map[string]rule.KindInfo {
	return dartKinds
}

// macroLoadInfos returns one rule.LoadInfo per shipped per-builder macro,
// pointing each rule kind at the correct `defs.bzl` under `dart/ext/<builder>/`.
// Kept in sync with `defaultBuilders()` in builder_registry.go — a separate
// test (`TestMacroKindsBackedByDefaultBuilders`) enforces the invariant.
func macroLoadInfos() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_dart//dart/ext/json_serializable:defs.bzl",
			Symbols: []string{"json_serializable_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/freezed:defs.bzl",
			Symbols: []string{"freezed_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/built_value:defs.bzl",
			Symbols: []string{"built_value_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/mockito:defs.bzl",
			Symbols: []string{"mockito_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/go_router:defs.bzl",
			Symbols: []string{"go_router_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/copy_with_extension_gen:defs.bzl",
			Symbols: []string{"copy_with_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/injectable:defs.bzl",
			Symbols: []string{"injectable_library"},
		},
		{
			Name:    "@rules_dart//dart/ext/drift:defs.bzl",
			Symbols: []string{"drift_library"},
		},
		{
			Name: "@rules_dart//dart/ext/stacked:defs.bzl",
			Symbols: []string{
				"stacked_router_library",
				"stacked_locator_library",
				"stacked_logger_library",
				"stacked_dialog_library",
				"stacked_bottomsheet_library",
				"stacked_form_library",
			},
		},
	}
}

func (*dartLang) Loads() []rule.LoadInfo {
	return append(
		[]rule.LoadInfo{
			{
				Name:    "@rules_dart//dart:defs.bzl",
				Symbols: []string{"dart_library", "dart_binary", "dart_test", "dart_codegen", "dart_aggregate_codegen", "dart_sqlcodegen"},
			},
		},
		macroLoadInfos()...,
	)
}

func (*dartLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	return append(
		[]rule.LoadInfo{
			{
				Name:    "@rules_dart//dart:defs.bzl",
				Symbols: []string{"dart_library", "dart_binary", "dart_test", "dart_codegen", "dart_aggregate_codegen", "dart_sqlcodegen"},
			},
		},
		macroLoadInfos()...,
	)
}

func (*dartLang) Fix(c *config.Config, f *rule.File) {}
