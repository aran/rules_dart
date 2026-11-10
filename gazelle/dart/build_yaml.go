package dart

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"go.yaml.in/yaml/v3"
)

// build_runner reads a package's builder options from its build.yaml, and
// rules_dart's builders never read that file: their options are the codegen
// targets' `config`. So Gazelle reads build.yaml for them, when it writes
// codegen for the package, and carries the one part a Bazel build has a
// place for -- `targets.$default.builders.<builder>.options` of a builder it
// writes targets for -- into those targets' `config`, as the JSON object
// build_runner would hand the builder. Everything else in the file
// (another target, `generate_for`, `enabled`, `dev_options`, a builder
// Gazelle does not run, a `build.<name>.yaml`) fails the run, naming what
// to do instead: no part of the file is silently left out of the build.

// buildYamlRemedy is what every error about the build.yaml-like file name
// says to do.
func buildYamlRemedy(name string) string {
	return "Gazelle carries into the build only `targets.$default.builders.<builder>.options`, " +
		"as that builder's `config`; a codegen macro's `srcs` choose the files it runs on. " +
		"State the rest in BUILD files, or add `# gazelle:exclude " + name + "` to the " +
		"package's BUILD file so that Gazelle does not read it"
}

// buildYamlState holds the builder options of each package's build.yaml,
// read once per run.
type buildYamlState struct {
	mu     sync.Mutex
	byRoot map[string]map[string]string // package root -> builder key -> options JSON
}

// configsOf returns the builder options the build.yaml of the package
// rooted at root, whose files are files, states, by builder key, recording
// an error in errs for each part of it Gazelle cannot carry into the build.
func (s *buildYamlState) configsOf(root string, files []string, c *config.Config, errs *generationErrors) map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cfgs, ok := s.byRoot[root]; ok {
		return cfgs
	}
	if s.byRoot == nil {
		s.byRoot = map[string]map[string]string{}
	}
	var cfgs map[string]string
	for _, name := range files {
		file := path.Join(root, name)
		switch {
		case name == "build.yaml":
			data, err := os.ReadFile(filepath.Join(c.RepoRoot, filepath.FromSlash(file)))
			if err != nil {
				errs.add(fmt.Sprintf("dart: %s: %v", file, err))
				continue
			}
			var problems []string
			cfgs, problems = builderOptions(data, knownBuilderKeys)
			for _, p := range problems {
				errs.add(fmt.Sprintf("dart: %s: %s. %s", file, p, buildYamlRemedy(name)))
			}
		case strings.HasPrefix(name, "build.") && strings.HasSuffix(name, ".yaml"):
			errs.add(fmt.Sprintf("dart: %s: build_runner reads it only when run with "+
				"`--config %s`, and a Bazel build has one set of builder options. %s",
				file, strings.TrimSuffix(strings.TrimPrefix(name, "build."), ".yaml"), buildYamlRemedy(name)))
		}
	}
	s.byRoot[root] = cfgs
	return cfgs
}

// knownBuilderKeys are the build.yaml keys of the builders whose options
// Gazelle carries into their targets.
var knownBuilderKeys = func() map[string]bool {
	m := map[string]bool{}
	for _, b := range defaultBuilders() {
		if b.Key != "" {
			m[b.Key] = true
		}
	}
	return m
}()

// builderOptions is the options build.yaml content states for each builder
// in known, as JSON objects by builder key, and a description of each part
// of it that is anything else.
func builderOptions(data []byte, known map[string]bool) (map[string]string, []string) {
	var doc interface{}
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, []string{"cannot be read: " + err.Error()}
	}
	if doc == nil {
		return nil, nil
	}
	var problems []string
	notCarried := func(at string) {
		problems = append(problems, fmt.Sprintf("`%s` is not carried into the build", at))
	}
	cfgs := map[string]string{}
	top, ok := doc.(map[string]interface{})
	if !ok {
		return nil, []string{"is not a map"}
	}
	for _, k := range sortedKeys(top) {
		if k != "targets" {
			notCarried(k)
			continue
		}
		targets, ok := asMap(top[k])
		if !ok {
			notCarried(k)
			continue
		}
		for _, t := range sortedKeys(targets) {
			at := "targets." + t
			if t != "$default" {
				notCarried(at)
				continue
			}
			target, ok := asMap(targets[t])
			if !ok {
				notCarried(at)
				continue
			}
			for _, tk := range sortedKeys(target) {
				if tk != "builders" {
					notCarried(at + "." + tk)
					continue
				}
				builders, ok := asMap(target[tk])
				if !ok {
					notCarried(at + "." + tk)
					continue
				}
				for _, bk := range sortedKeys(builders) {
					at := at + ".builders." + bk
					key := normalizeBuilderKey(bk)
					if !known[key] {
						problems = append(problems, fmt.Sprintf(
							"`%s` names a builder whose options Gazelle cannot carry into "+
								"the build (it can for %s)", at, strings.Join(sortedKeys(known), ", ")))
						continue
					}
					builder, ok := asMap(builders[bk])
					if !ok {
						notCarried(at)
						continue
					}
					for _, field := range sortedKeys(builder) {
						if field != "options" {
							notCarried(at + "." + field)
						}
					}
					if _, stated := builder["options"]; !stated {
						continue
					}
					opts, isMap := asMap(builder["options"])
					if !isMap {
						notCarried(at + ".options")
						continue
					}
					j, err := json.Marshal(opts)
					if err != nil {
						problems = append(problems, fmt.Sprintf("`%s.options` has no JSON form: %v", at, err))
						continue
					}
					if _, twice := cfgs[key]; twice {
						problems = append(problems, fmt.Sprintf("`%s` states the options of `%s` a second time", at, key))
						continue
					}
					cfgs[key] = string(j)
				}
			}
		}
	}
	return cfgs, problems
}

// asMap is v as a YAML map with string keys; an absent or empty value is an
// empty map.
func asMap(v interface{}) (map[string]interface{}, bool) {
	if v == nil {
		return map[string]interface{}{}, true
	}
	m, ok := v.(map[string]interface{})
	return m, ok
}

// normalizeBuilderKey is a build.yaml builder key in its full
// `<package>:<builder>` form: a bare `<package>` names the builder of that
// name, as build_runner reads it, and `|` is the older separator.
func normalizeBuilderKey(key string) string {
	key = strings.Replace(key, "|", ":", 1)
	if !strings.Contains(key, ":") {
		return key + ":" + key
	}
	return key
}

// withBuildYaml is the registry the codegen of directory args.Rel uses: the
// directory's, with the options its package's build.yaml states for a
// builder as that builder's Config. A build.yaml and a
// `dart_builder_config` directive that state different options for one
// builder are an error.
func (d *dartLang) withBuildYaml(args language.GenerateArgs, registry *builderRegistry) *builderRegistry {
	root, err := packageRootOf(args.Rel)
	if err != nil || registry == nil {
		return registry
	}
	cfgs := d.buildYaml.configsOf(root, d.scan.visibleFiles(root), args.Config, &d.errs)
	if len(cfgs) == 0 {
		return registry
	}
	out := registry.clone()
	for _, ann := range sortedKeys(out.byAnnotation) {
		for _, info := range out.byAnnotation[ann] {
			cfg, ok := cfgs[info.Key]
			if info.Key == "" || !ok {
				continue
			}
			if info.Config != "" && !sameJSON(info.Config, cfg) {
				d.errs.add(fmt.Sprintf(
					"dart: %s: the options of `%s` are stated twice, differently: %s by "+
						"`# gazelle:dart_builder_config %s`, %s by %s; state them once, or make the two agree",
					dirName(args.Rel), info.Key, info.Config, info.Annotation, cfg, path.Join(root, "build.yaml")))
				continue
			}
			if info.Config == "" {
				info.Config = cfg
			}
		}
	}
	return out
}

// sameJSON reports whether two JSON texts hold the same value.
func sameJSON(a, b string) bool {
	var x, y interface{}
	if json.Unmarshal([]byte(a), &x) != nil || json.Unmarshal([]byte(b), &y) != nil {
		return false
	}
	return reflect.DeepEqual(x, y)
}
