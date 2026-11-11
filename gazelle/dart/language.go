// Package dart implements a Gazelle language extension for Dart.
//
// It generates dart_library, dart_binary, and dart_test BUILD targets
// from Dart source files by parsing import statements and applying
// Dart package conventions.
package dart

import (
	"flag"
	"path"
	"path/filepath"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const dartName = "dart"

// dartLang implements language.Language for Dart.
type dartLang struct {
	analysis  analysisState
	errs      generationErrors
	scan      scanState
	buildYaml buildYamlState
	stale     staleBuildFiles
	cycles    cycleState
	// mode is Gazelle's -mode: "fix" (the default), "print" or "diff".
	mode string
	// external is the builders the repository root's `dart_builder`
	// directives register (external.go).
	external []*builderInfo
}

// builders is every registered builder: the shipped ones, then the
// repository's.
func (d *dartLang) builders() []*builderInfo {
	return append(defaultBuilders(), d.external...)
}

// NewLanguage creates a new Dart language extension for Gazelle.
func NewLanguage() language.Language {
	return &dartLang{}
}

func (*dartLang) Name() string { return dartName }

func (*dartLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {}

// CheckFlags reads Gazelle's -mode, which decides whether a BUILD file
// under a package's lib/ is deleted (lib_dir.go), and the builders the
// repository's root registers, whose macros are rule kinds Gazelle must know
// before it reads any directory (external.go).
func (d *dartLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error {
	if f := fs.Lookup("mode"); f != nil {
		d.mode = f.Value.String()
	}
	external, err := rootBuilders(c)
	if err != nil {
		return err
	}
	d.external = external
	if c.Exts == nil {
		c.Exts = map[string]interface{}{}
	}
	c.Exts[extKeyExternalBuilders] = external
	return nil
}

func (*dartLang) KnownDirectives() []string {
	return []string{
		keyPackageName,
		"dart_pub_deps_repo",
		// A builder from another module, at the repository's root
		// (external.go), and directives that tune registered builders.
		keyBuilder,
		"dart_builder_runtime_dep",
		"dart_builder_config",
		// A part of the build.yaml beside it the build goes without
		// (build_yaml.go).
		keyBuildYamlIgnore,
		// The `language_version` of the package, for a package whose
		// pubspec.yaml does not state it or that has none.
		keyLanguageVersion,
		// Packages that import each other, built as one target (cycle.go).
		keyCycle,
	}
}

func (d *dartLang) Configure(c *config.Config, rel string, f *rule.File) {
	if _, ok := c.Exts[extKeyBuilderRegistry]; !ok {
		// The shipped builders, which a directory with no BUILD file above
		// it uses too.
		builderRegistryOf(c)
	}
	configurePackageDecl(c, rel, f)
	scopePackageFacts(c, rel)
	if f == nil {
		return
	}
	for _, d := range f.Directives {
		switch d.Key {
		case keyPackageName, keyLanguageVersion:
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts[d.Key] = &directiveValue{Value: d.Value, File: path.Join(rel, filepath.Base(f.Path))}
		case "dart_pub_deps_repo":
			// Store pub deps repository name for external dep labels
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts["dart_pub_deps_repo"] = d.Value
		}
	}
	d.buildYaml.configureIgnores(rel, f)
	d.configureCycles(c, rel, f)
	if rel != "" {
		d.refuseNestedBuilders(rel, f)
	}
	// Merge dart_builder* directives into the per-config registry. Done
	// separately so dart_builder configuration is decoupled from the
	// existing single-line directives above.
	configureBuilderDirectives(c, f)
}

func (d *dartLang) Kinds() map[string]rule.KindInfo {
	return dartKinds(d.builders())
}

func (d *dartLang) Loads() []rule.LoadInfo {
	return append(
		[]rule.LoadInfo{
			{
				Name:    "@rules_dart//dart:defs.bzl",
				Symbols: []string{"dart_library", "dart_binary", "dart_test", "dart_codegen", "dart_aggregate_codegen", "dart_sqlcodegen", "dart_analysis_options", "dart_analysis_config", "dart_package_metadata", "dart_package_member", "dart_package_cycle"},
			},
		},
		macroLoads(d.builders())...,
	)
}

func (d *dartLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	return append(
		[]rule.LoadInfo{
			{
				Name:    "@rules_dart//dart:defs.bzl",
				Symbols: []string{"dart_library", "dart_binary", "dart_test", "dart_codegen", "dart_aggregate_codegen", "dart_sqlcodegen", "dart_analysis_options", "dart_analysis_config", "dart_package_metadata", "dart_package_member", "dart_package_cycle"},
			},
		},
		macroLoads(d.builders())...,
	)
}

func (*dartLang) Fix(c *config.Config, f *rule.File) {}
