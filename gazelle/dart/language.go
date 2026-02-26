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
		}
	}
}

func (*dartLang) Kinds() map[string]rule.KindInfo {
	return dartKinds
}

func (*dartLang) Loads() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_dart//dart:defs.bzl",
			Symbols: []string{"dart_library", "dart_binary", "dart_test"},
		},
	}
}

func (*dartLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_dart//dart:defs.bzl",
			Symbols: []string{"dart_library", "dart_binary", "dart_test"},
		},
	}
}

func (*dartLang) Fix(c *config.Config, f *rule.File) {}
