package dart

import (
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const (
	analysisOptionsFile = "analysis_options.yaml"
	// analysisOptionsName is the target Gazelle emits beside each
	// analysis_options.yaml. analysisOptionsAltName replaces it in the rare
	// directory where another rule already holds that name.
	analysisOptionsName    = "analysis_options"
	analysisOptionsAltName = "analysis_options_yaml"
	// analysisConfigName is the repository's one dart_analysis_config, in the
	// root package.
	analysisConfigName = "analysis_config"
)

// analysisState remembers, for one Gazelle run, which directories were
// generated and what options target each holds. The root package is generated
// last in a full run (Gazelle walks in post-order), so by then every visited
// directory is known. A run that did not visit some directory (`gazelle sub`,
// `-r=false`) leaves its entries in the config untouched: see
// analysisConfigRule.
type analysisState struct {
	mu      sync.Mutex
	visited map[string]string // dir rel -> options label, "" when no yaml
}

func (s *analysisState) record(rel, lbl string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.visited == nil {
		s.visited = map[string]string{}
	}
	s.visited[rel] = lbl
}

func (s *analysisState) snapshot() map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]string, len(s.visited))
	for k, v := range s.visited {
		out[k] = v
	}
	return out
}

func optionsLabel(rel, name string) string {
	if rel == "" {
		return ":" + name
	}
	return "//" + rel + ":" + name
}

// analysisRules returns the rules the analysis feature adds to this directory:
// a dart_analysis_options beside an analysis_options.yaml, and in the root
// package the dart_analysis_config listing them.
func (d *dartLang) analysisRules(args language.GenerateArgs, taken map[string]bool) (gen []*rule.Rule, imports []interface{}, empty []*rule.Rule) {
	hasYaml := false
	for _, f := range args.RegularFiles {
		if f == analysisOptionsFile {
			hasYaml = true
			break
		}
	}

	lbl := ""
	if hasYaml {
		name := analysisOptionsTargetName(args.File, taken)
		r := rule.NewRule("dart_analysis_options", name)
		r.SetAttr("src", analysisOptionsFile)
		r.SetAttr("visibility", []string{"//visibility:public"})
		gen = append(gen, r)
		is := &importSet{packages: map[string]bool{}}
		if data, err := os.ReadFile(filepath.Join(args.Dir, analysisOptionsFile)); err == nil {
			for _, pkg := range includedPackages(string(data)) {
				is.packages[pkg] = true
			}
		}
		if len(is.packages) > 0 {
			imports = append(imports, is)
		} else {
			imports = append(imports, nil)
		}
		lbl = optionsLabel(args.Rel, name)
	}
	d.analysis.record(args.Rel, lbl)

	// Options rules for a yaml that is gone. Only ones naming the standard
	// file: a dart_analysis_options for some other file is the user's.
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "dart_analysis_options" && r.AttrString("src") == analysisOptionsFile && !hasYaml {
				empty = append(empty, rule.NewRule(r.Kind(), r.Name()))
			}
		}
	}

	if args.Rel == "" {
		if cfg := analysisConfigRule(args, d.analysis.snapshot()); cfg != nil {
			gen = append(gen, cfg)
			imports = append(imports, nil)
		}
	}
	return gen, imports, empty
}

// analysisOptionsTargetName is the name of the options target for this
// directory: the name of an existing dart_analysis_options for the yaml, else
// `analysis_options`, else the alternative when another rule holds that name.
func analysisOptionsTargetName(f *rule.File, taken map[string]bool) string {
	occupied := map[string]bool{}
	for n := range taken {
		occupied[n] = true
	}
	if f != nil {
		for _, r := range f.Rules {
			if r.Kind() == "dart_analysis_options" && r.AttrString("src") == analysisOptionsFile {
				return r.Name()
			}
			occupied[r.Name()] = true
		}
	}
	if occupied[analysisOptionsName] {
		return analysisOptionsAltName
	}
	return analysisOptionsName
}

// analysisConfigRule builds the root dart_analysis_config. Its options are the
// targets of every directory visited this run, plus the existing entries for
// directories this run did not visit whose yaml still exists. A run that
// visits a directory therefore decides its entry, and a run that does not
// cannot drop it. An existing config is never deleted, since `.bazelrc` files
// name it: with nothing to list it keeps an empty `options`, which means the
// SDK's defaults. With no config and nothing to list, none is created.
func analysisConfigRule(args language.GenerateArgs, visited map[string]string) *rule.Rule {
	var existing *rule.Rule
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Name() == analysisConfigName {
				if r.Kind() != "dart_analysis_config" {
					log.Printf("dart: %s is not a dart_analysis_config; not generating the analysis config", optionsLabel("", analysisConfigName))
					return nil
				}
				existing = r
			}
		}
	}

	set := map[string]bool{}
	for _, lbl := range visited {
		if lbl != "" {
			set[lbl] = true
		}
	}
	if existing != nil {
		for _, s := range existing.AttrStrings("options") {
			l, err := label.Parse(s)
			if err != nil || l.Repo != "" {
				continue
			}
			if _, ok := visited[l.Pkg]; ok {
				continue // this run decided that directory
			}
			if _, err := os.Stat(filepath.Join(args.Dir, filepath.FromSlash(l.Pkg), analysisOptionsFile)); err != nil {
				continue
			}
			set[optionsLabel(l.Pkg, l.Name)] = true
		}
	}

	if len(set) == 0 && existing == nil {
		return nil
	}
	options := make([]string, 0, len(set))
	for s := range set {
		options = append(options, s)
	}
	// Buildifier's label order: same-package labels first.
	sort.Slice(options, func(i, j int) bool {
		li, lj := strings.HasPrefix(options[i], ":"), strings.HasPrefix(options[j], ":")
		if li != lj {
			return li
		}
		return options[i] < options[j]
	})
	r := rule.NewRule("dart_analysis_config", analysisConfigName)
	r.SetAttr("options", options)
	r.SetAttr("visibility", []string{"//visibility:public"})
	return r
}

// includedPackages returns the Dart packages a yaml's top-level `include:`
// names by `package:` URI, in order and without duplicates. `include` is a
// scalar or a list; relative includes name no package.
func includedPackages(yaml string) []string {
	var values []string
	lines := strings.Split(yaml, "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimRight(lines[i], "\r")
		if !strings.HasPrefix(line, "include:") {
			continue
		}
		rest := strings.TrimSpace(stripYamlComment(strings.TrimPrefix(line, "include:")))
		switch {
		case strings.HasPrefix(rest, "["):
			rest = strings.TrimSuffix(strings.TrimPrefix(rest, "["), "]")
			values = append(values, strings.Split(rest, ",")...)
		case rest != "":
			values = append(values, rest)
		default:
			for i+1 < len(lines) {
				item := strings.TrimSpace(stripYamlComment(strings.TrimRight(lines[i+1], "\r")))
				if item == "" {
					i++
					continue
				}
				if !strings.HasPrefix(item, "-") {
					break
				}
				values = append(values, strings.TrimSpace(strings.TrimPrefix(item, "-")))
				i++
			}
		}
	}
	var pkgs []string
	seen := map[string]bool{}
	for _, v := range values {
		v = strings.Trim(strings.TrimSpace(v), `"'`)
		if !strings.HasPrefix(v, "package:") {
			continue
		}
		pkg, _, _ := strings.Cut(strings.TrimPrefix(v, "package:"), "/")
		if pkg != "" && !seen[pkg] {
			seen[pkg] = true
			pkgs = append(pkgs, pkg)
		}
	}
	return pkgs
}

// stripYamlComment drops a trailing ` # comment`, leaving quoted values alone
// (a `#` inside a package URI does not occur).
func stripYamlComment(s string) string {
	if strings.HasPrefix(strings.TrimSpace(s), "#") {
		return ""
	}
	if i := strings.Index(s, " #"); i >= 0 {
		return s[:i]
	}
	return s
}
