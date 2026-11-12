package dart

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// keyBuilder is the directive registering a builder another module ships:
//
//	# gazelle:dart_builder <Annotation> macro=<file>%<symbol> shim=<label> produces=<ext>[,<ext>] runtime_dep=<label> [key=<package>:<builder>]
//
// `macro` is the builder's codegen macro, which Gazelle writes for a source
// carrying only this builder's annotation; `shim` its shim binary, which
// Gazelle runs in a `dart_codegen` for a source carrying several builders'
// annotations; `produces` the extensions it writes (a `.<name>.g.part`
// extension makes it a SharedPartBuilder, merged into `<src>.g.dart`);
// `runtime_dep` the library its annotation is in, the macro's default
// `annotation_dep`; `key` its key in build_runner's build.yaml, whose
// options there become its `config`.
//
// Its macro is a rule kind Gazelle must know before it reads any directory,
// so the directive is read from the repository root's BUILD file alone, as
// Gazelle reads `# gazelle:repository_macro` from the WORKSPACE file.
const keyBuilder = "dart_builder"

const extKeyExternalBuilders = "dart_external_builders"

const builderForm = "`# gazelle:dart_builder <Annotation> macro=<file>%<symbol> " +
	"shim=<label> produces=<ext>[,<ext>] runtime_dep=<label> [key=<package>:<builder>]`"

// registeredBuilders is every builder registered for the repository c is
// of: the shipped ones, then those its root's `dart_builder` directives
// register.
func registeredBuilders(c *config.Config) []*builderInfo {
	external, _ := c.Exts[extKeyExternalBuilders].([]*builderInfo)
	return append(defaultBuilders(), external...)
}

// rootBuilders is the builders the `dart_builder` directives of the BUILD
// file at c's repository root register.
func rootBuilders(c *config.Config) ([]*builderInfo, error) {
	f, err := rootBuildFile(c)
	if err != nil || f == nil {
		return nil, err
	}
	where := filepath.Base(f.Path)
	taken := map[string]string{} // annotation or macro kind -> who has it
	for _, b := range defaultBuilders() {
		taken[b.Annotation] = "a builder rules_dart ships"
		taken[macroRuleKind(b.Macro)] = "a macro rules_dart ships"
	}
	for kind := range dartKinds(nil) {
		taken[kind] = "a rule rules_dart ships"
	}
	var out []*builderInfo
	for _, d := range f.Directives {
		if d.Key != keyBuilder {
			continue
		}
		b, err := parseBuilder(d.Value)
		if err != nil {
			return nil, fmt.Errorf("dart: %s: `# gazelle:%s %s`: %v; the form is %s",
				where, keyBuilder, d.Value, err, builderForm)
		}
		kind := macroRuleKind(b.Macro)
		for _, name := range []string{b.Annotation, kind} {
			if who, ok := taken[name]; ok {
				return nil, fmt.Errorf("dart: %s: `# gazelle:%s %s`: `%s` is %s; "+
					"register each annotation once, with a macro of its own",
					where, keyBuilder, d.Value, name, who)
			}
		}
		taken[b.Annotation] = "registered by an earlier `# gazelle:" + keyBuilder + "`"
		taken[kind] = "the macro of an earlier `# gazelle:" + keyBuilder + "`"
		out = append(out, b)
	}
	return out, nil
}

// rootBuildFile is the BUILD file at c's repository root, nil when there is
// none.
func rootBuildFile(c *config.Config) (*rule.File, error) {
	for _, name := range c.ValidBuildFileNames {
		p := filepath.Join(c.RepoRoot, name)
		if _, err := os.Stat(p); err != nil {
			continue
		}
		f, err := rule.LoadFile(p, "")
		if err != nil {
			return nil, fmt.Errorf("dart: %s: %v", name, err)
		}
		return f, nil
	}
	return nil, nil
}

// parseBuilder is the builder a `dart_builder` directive's value registers.
func parseBuilder(value string) (*builderInfo, error) {
	fields := strings.Fields(value)
	if len(fields) == 0 || strings.Contains(fields[0], "=") {
		return nil, fmt.Errorf("it names no annotation")
	}
	b := &builderInfo{Annotation: fields[0], Consumes: []string{".dart"}}
	seen := map[string]bool{}
	for _, field := range fields[1:] {
		k, v, ok := strings.Cut(field, "=")
		if !ok || v == "" {
			return nil, fmt.Errorf("`%s` is not `<attribute>=<value>`", field)
		}
		if seen[k] {
			return nil, fmt.Errorf("`%s` is stated twice", k)
		}
		seen[k] = true
		switch k {
		case "macro":
			if macroFile(v) == "" || macroRuleKind(v) == "" {
				return nil, fmt.Errorf("`macro=%s` is not `<file>%%<symbol>`", v)
			}
			if _, err := label.Parse(macroFile(v)); err != nil {
				return nil, fmt.Errorf("`macro=%s`: %v", v, err)
			}
			b.Macro = v
		case "shim":
			if _, err := label.Parse(v); err != nil {
				return nil, fmt.Errorf("`shim=%s`: %v", v, err)
			}
			b.ShimLabel = v
		case "produces":
			for _, ext := range strings.Split(v, ",") {
				if !strings.HasPrefix(ext, ".") || len(ext) < 2 {
					return nil, fmt.Errorf("`produces=%s`: `%s` is not an extension", v, ext)
				}
				b.Produces = append(b.Produces, ext)
			}
			b.SharedPart = len(b.Produces) == 1 && strings.HasSuffix(b.Produces[0], ".g.part")
		case "runtime_dep":
			if _, err := label.Parse(v); err != nil {
				return nil, fmt.Errorf("`runtime_dep=%s`: %v", v, err)
			}
			b.RuntimeDep = v
			b.defaultRuntimeDep = v
		case "key":
			b.Key = normalizeBuilderKey(v)
		default:
			return nil, fmt.Errorf("`%s` is not an attribute of a builder", k)
		}
	}
	var missing []string
	for _, k := range []string{"macro", "shim", "produces", "runtime_dep"} {
		if !seen[k] {
			missing = append(missing, "`"+k+"`")
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("it states no %s", strings.Join(missing, ", "))
	}
	return b, nil
}

// refuseNestedBuilders records an error for each `dart_builder` directive
// in f, the BUILD file of directory rel below the repository's root, where
// Gazelle does not read it.
func (d *dartLang) refuseNestedBuilders(rel string, f *rule.File) {
	for _, dir := range f.Directives {
		if dir.Key == keyBuilder {
			d.errs.add(fmt.Sprintf(
				"dart: %s: `# gazelle:%s` registers a builder for the whole repository, "+
					"and Gazelle reads it only from the BUILD file at the repository's root; move it there",
				path.Join(rel, filepath.Base(f.Path)), keyBuilder))
		}
	}
}
