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
	"github.com/bazelbuild/bazel-gazelle/rule"
	"go.yaml.in/yaml/v3"
)

// build_runner reads a package's builder options from its build.yaml, and
// rules_dart's builders never read that file: their options are the codegen
// targets' `config`. So Gazelle reads build.yaml for them, when it writes
// codegen for the package, and carries the one part a Bazel build has a
// place for -- `targets.$default.builders.<builder>.options` of a builder it
// writes targets for -- into those targets' `config`, as the JSON object
// build_runner would hand the builder. Every other part of the file
// (another target, `generate_for`, `enabled`, `dev_options`, a builder
// Gazelle does not run, the options of one no source of the package needs) fails the run, each part named by its key path and
// line, until a `# gazelle:dart_build_yaml_ignore <path>` in the BUILD file
// beside it acknowledges that the build goes without it. A
// `build.<name>.yaml` fails the run whole: no part of either file is left
// out of the build silently.

// keyBuildYamlIgnore acknowledges one part of the build.yaml beside the
// BUILD file stating it, by key path, that Gazelle cannot carry into the
// build, so that Gazelle carries the rest.
const keyBuildYamlIgnore = "dart_build_yaml_ignore"

// buildYamlPart is a part of a build.yaml Gazelle cannot carry into the
// build: its key path, the line of its key, and why.
type buildYamlPart struct {
	path string
	line int
	why  string
}

// buildYamlRead is what one build.yaml states: the builder options it
// carries, by builder key, the parts it cannot carry, and the problems no
// ignore covers: the file unreadable (unread, true), a builder's options
// stated twice.
type buildYamlRead struct {
	cfgs map[string]string
	// optionsAt is where each of cfgs is stated: the key path of its options
	// and the line of their key.
	optionsAt map[string]buildYamlPart
	parts     []buildYamlPart
	errors    []string
	unread    bool
}

// buildYamlIgnore is one `dart_build_yaml_ignore` directive: the key path it
// names and the BUILD file stating it.
type buildYamlIgnore struct {
	path, file string
}

// buildYamlState holds what each package's build.yaml states, read once per
// run, and the ignores each directory's BUILD file states.
type buildYamlState struct {
	mu      sync.Mutex
	byRoot  map[string]map[string]string // package root -> builder key -> options JSON
	ignores map[string][]buildYamlIgnore // directory -> its ignores
	checked map[string]bool              // directories whose ignores are checked
}

// configureIgnores records the `dart_build_yaml_ignore` directives of f, the
// BUILD file of directory rel. They apply to that directory's build.yaml
// alone, not to those below it: a key path names a part of one file.
func (s *buildYamlState) configureIgnores(rel string, f *rule.File) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, d := range f.Directives {
		if d.Key != keyBuildYamlIgnore {
			continue
		}
		if s.ignores == nil {
			s.ignores = map[string][]buildYamlIgnore{}
		}
		s.ignores[rel] = append(s.ignores[rel], buildYamlIgnore{
			path: strings.TrimSpace(d.Value),
			file: path.Join(rel, filepath.Base(f.Path)),
		})
	}
}

// buildYamlIgnoreHint is how the error about part p of the build.yaml of
// directory root says to build without it.
func buildYamlIgnoreHint(root, p string) string {
	return fmt.Sprintf("to build without it, add `# gazelle:%s %s` to the BUILD file in %s",
		keyBuildYamlIgnore, p, dirName(root))
}

// configsOf returns the builder options the build.yaml of the package
// rooted at root, whose files are files, states, by builder key, recording
// an error in errs for each part of it Gazelle cannot carry into the build
// that no ignore of root acknowledges. When used is not nil, the options of
// a builder it does not hold are such a part: the package's sources carry
// none of the annotations the builder runs on.
func (s *buildYamlState) configsOf(root string, files []string, c *config.Config, used map[string]bool, errs *generationErrors) map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cfgs, ok := s.byRoot[root]; ok {
		return cfgs
	}
	if s.byRoot == nil {
		s.byRoot = map[string]map[string]string{}
	}
	var cfgs map[string]string
	sawYaml := false
	for _, name := range files {
		file := path.Join(root, name)
		switch {
		case name == "build.yaml":
			data, err := os.ReadFile(filepath.Join(c.RepoRoot, filepath.FromSlash(file)))
			if err != nil {
				errs.add(fmt.Sprintf("dart: %s: %v", file, err))
				continue
			}
			registry, _ := c.Exts[extKeyBuilderRegistry].(*builderRegistry)
			read := builderOptions(data, registry.keys())
			cfgs = read.cfgs
			sawYaml = true
			for _, e := range read.errors {
				if read.unread {
					e += fmt.Sprintf("; fix it, or add `# gazelle:exclude build.yaml` to the BUILD file in %s "+
						"so that Gazelle does not read it", dirName(root))
				}
				errs.add(fmt.Sprintf("dart: %s:%s", file, e))
			}
			if read.unread {
				continue
			}
			ignored := map[string]bool{}
			for _, ig := range s.ignores[root] {
				ignored[ig.path] = true
			}
			parts := read.parts
			if used != nil {
				for _, key := range sortedKeys(read.cfgs) {
					if used[key] {
						continue
					}
					at := read.optionsAt[key]
					at.why = fmt.Sprintf("states the options of `%s`, which no source of the package needs: "+
						"it runs on %s, which none of them carries, so no `config` carries the options",
						key, annotationsOf(registry, key))
					parts = append(parts, at)
				}
			}
			for _, p := range parts {
				if ignored[p.path] {
					delete(ignored, p.path)
					continue
				}
				errs.add(fmt.Sprintf("dart: %s:%d: `%s` %s; %s",
					file, p.line, p.path, p.why, buildYamlIgnoreHint(root, p.path)))
			}
			s.reportStale(root, file, ignored, errs)
		case strings.HasPrefix(name, "build.") && strings.HasSuffix(name, ".yaml"):
			errs.add(fmt.Sprintf("dart: %s: build_runner reads it only when run with "+
				"`--config %s`, and a Bazel build has one set of builder options; "+
				"state them in build.yaml, or add `# gazelle:exclude %s` to the BUILD file in %s "+
				"so that Gazelle does not read it",
				file, strings.TrimSuffix(strings.TrimPrefix(name, "build."), ".yaml"), name, dirName(root)))
		}
	}
	if !sawYaml {
		s.reportStale(root, "", s.allIgnored(root), errs)
	}
	if s.checked == nil {
		s.checked = map[string]bool{}
	}
	s.checked[root] = true
	s.byRoot[root] = cfgs
	return cfgs
}

// reportStale records an error for each ignore of directory root that
// names no part of its build.yaml, file, Gazelle cannot carry: an ignore
// that matches nothing states a fact the build does not hold.
func (s *buildYamlState) reportStale(root, file string, unmatched map[string]bool, errs *generationErrors) {
	seen := map[string]bool{}
	for _, ig := range s.ignores[root] {
		if seen[ig.path] {
			errs.add(fmt.Sprintf("dart: %s: `# gazelle:%s %s` is stated twice; state it once",
				ig.file, keyBuildYamlIgnore, ig.path))
			continue
		}
		seen[ig.path] = true
		if !unmatched[ig.path] {
			continue
		}
		what := "names no part of " + file + " that Gazelle cannot carry into the build"
		if file == "" {
			what = "names a part of a build.yaml in " + dirName(root) +
				", and Gazelle reads none there (it is absent or excluded)"
		}
		errs.add(fmt.Sprintf("dart: %s: `# gazelle:%s %s` %s; remove it",
			ig.file, keyBuildYamlIgnore, ig.path, what))
	}
}

// allIgnored is the key paths directory rel's ignores name.
func (s *buildYamlState) allIgnored(rel string) map[string]bool {
	out := map[string]bool{}
	for _, ig := range s.ignores[rel] {
		out[ig.path] = true
	}
	return out
}

// checkIgnores records an error for each ignore of a directory Gazelle
// generated in, rel, whose build.yaml it did not read because it writes no
// codegen there, that names no part of that file Gazelle cannot carry.
func (d *dartLang) checkIgnores(c *config.Config, rel string) {
	s := &d.buildYaml
	s.mu.Lock()
	if s.checked[rel] || len(s.ignores[rel]) == 0 {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()
	files := d.scan.visibleFiles(rel)
	if hasFile(files, "build.yaml") {
		// Reading it checks them.
		s.configsOf(rel, []string{"build.yaml"}, c, nil, &d.errs)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reportStale(rel, "", s.allIgnored(rel), &d.errs)
	if s.checked == nil {
		s.checked = map[string]bool{}
	}
	s.checked[rel] = true
}

// builderOptions is what build.yaml content states: the options of each
// builder in known, as JSON objects by builder key, each other part of it,
// and what is wrong with the file as a whole.
func builderOptions(data []byte, known map[string]bool) buildYamlRead {
	var read buildYamlRead
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		read.errors, read.unread = append(read.errors, " cannot be read: "+err.Error()), true
		return read
	}
	if len(doc.Content) == 0 {
		return read
	}
	top := doc.Content[0]
	// Decoding finds what the node tree does not: a key stated twice.
	var check interface{}
	if err := top.Decode(&check); err != nil {
		read.errors, read.unread = append(read.errors, " cannot be read: "+err.Error()), true
		return read
	}
	if top.Kind == yaml.ScalarNode && top.Tag == "!!null" {
		return read
	}
	if top.Kind != yaml.MappingNode {
		read.errors, read.unread = append(read.errors, fmt.Sprintf("%d: is not a map", top.Line)), true
		return read
	}
	notCarried := func(at string, key *yaml.Node) {
		read.parts = append(read.parts, buildYamlPart{at, key.Line,
			"is not carried into the build: Gazelle carries only " +
				"`targets.$default.builders.<builder>.options`, as that builder's `config`, " +
				"and a codegen macro's `srcs` choose the files it runs on"})
	}
	read.cfgs = map[string]string{}
	read.optionsAt = map[string]buildYamlPart{}
	for _, t := range entries(top) {
		if t.key.Value != "targets" || !isMap(t.value) {
			notCarried(t.key.Value, t.key)
			continue
		}
		for _, tg := range entries(t.value) {
			at := "targets." + tg.key.Value
			if tg.key.Value != "$default" || !isMap(tg.value) {
				notCarried(at, tg.key)
				continue
			}
			for _, tk := range entries(tg.value) {
				if tk.key.Value != "builders" || !isMap(tk.value) {
					notCarried(at+"."+tk.key.Value, tk.key)
					continue
				}
				for _, b := range entries(tk.value) {
					at := at + ".builders." + b.key.Value
					key := normalizeBuilderKey(b.key.Value)
					if !known[key] {
						read.parts = append(read.parts, buildYamlPart{at, b.key.Line, fmt.Sprintf(
							"names a builder Gazelle writes no targets for, so no `config` "+
								"carries its options (it writes them for %s)", strings.Join(sortedKeys(known), ", "))})
						continue
					}
					if !isMap(b.value) {
						notCarried(at, b.key)
						continue
					}
					var opts *entry
					for _, f := range entries(b.value) {
						if f.key.Value != "options" {
							notCarried(at+"."+f.key.Value, f.key)
							continue
						}
						f := f
						opts = &f
					}
					if opts == nil {
						continue
					}
					if !isMap(opts.value) {
						notCarried(at+".options", opts.key)
						continue
					}
					var v interface{}
					_ = opts.value.Decode(&v)
					if v == nil {
						v = map[string]interface{}{}
					}
					j, err := json.Marshal(v)
					if err != nil {
						read.parts = append(read.parts, buildYamlPart{at + ".options", opts.key.Line,
							"has no JSON form, which a `config` is: " + err.Error()})
						continue
					}
					if _, twice := read.cfgs[key]; twice {
						read.errors = append(read.errors, fmt.Sprintf(
							"%d: `%s` states the options of `%s` a second time; state them once",
							b.key.Line, at, key))
						continue
					}
					read.cfgs[key] = string(j)
					read.optionsAt[key] = buildYamlPart{path: at + ".options", line: opts.key.Line}
				}
			}
		}
	}
	return read
}

// entry is one key and its value in a YAML map.
type entry struct {
	key, value *yaml.Node
}

// entries is the entries of YAML map node n, in the order the file states
// them; an alias stands for the node it names.
func entries(n *yaml.Node) []entry {
	n = resolveAlias(n)
	var out []entry
	for i := 0; i+1 < len(n.Content); i += 2 {
		out = append(out, entry{n.Content[i], resolveAlias(n.Content[i+1])})
	}
	return out
}

func resolveAlias(n *yaml.Node) *yaml.Node {
	for n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

// isMap reports whether n is a YAML map, or absent (`key:` with no value),
// which build_runner reads as an empty one.
func isMap(n *yaml.Node) bool {
	n = resolveAlias(n)
	return n.Kind == yaml.MappingNode || (n.Kind == yaml.ScalarNode && n.Tag == "!!null")
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
func (d *dartLang) withBuildYaml(args language.GenerateArgs, registry *builderRegistry, scan *packageScan) *builderRegistry {
	root, err := packageRootOf(args.Config, args.Rel)
	if err != nil || registry == nil {
		return registry
	}
	used := map[string]bool{}
	for _, anns := range scan.annotated {
		for _, ann := range anns {
			for _, info := range registry.lookup(ann) {
				used[info.Key] = true
			}
		}
	}
	cfgs := d.buildYaml.configsOf(root, d.scan.visibleFiles(root), args.Config, used, &d.errs)
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

// annotationsOf names the annotations the builder with build.yaml key runs
// on, for a message.
func annotationsOf(r *builderRegistry, key string) string {
	var anns []string
	for _, ann := range sortedKeys(r.byAnnotation) {
		for _, info := range r.byAnnotation[ann] {
			if info.Key == key {
				anns = append(anns, "`@"+ann+"`")
			}
		}
	}
	return strings.Join(anns, ", ")
}

// sameJSON reports whether two JSON texts hold the same value.
func sameJSON(a, b string) bool {
	var x, y interface{}
	if json.Unmarshal([]byte(a), &x) != nil || json.Unmarshal([]byte(b), &y) != nil {
		return false
	}
	return reflect.DeepEqual(x, y)
}
