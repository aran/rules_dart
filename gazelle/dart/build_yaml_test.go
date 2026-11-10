package dart

import (
	"reflect"
	"strings"
	"testing"
)

func TestBuilderOptionsCarriesOptions(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true, "freezed:freezed": true}
	read := builderOptions([]byte(`
targets:
  $default:
    builders:
      json_serializable:
        options:
          field_rename: snake
          explicit_to_json: true
          any_map: false
          checked: null
          max: 3
      freezed|freezed:
        options: {}
`), known)
	cfgs := read.cfgs
	if len(read.parts) != 0 || len(read.errors) != 0 {
		t.Fatalf("problems: %v %v", read.parts, read.errors)
	}
	want := map[string]string{
		"json_serializable:json_serializable": `{"any_map":false,"checked":null,"explicit_to_json":true,"field_rename":"snake","max":3}`,
		"freezed:freezed":                     `{}`,
	}
	if !reflect.DeepEqual(cfgs, want) {
		t.Errorf("got %v, want %v", cfgs, want)
	}
}

func TestBuilderOptionsEmptyFile(t *testing.T) {
	read := builderOptions([]byte("# nothing\n"), nil)
	if len(read.cfgs) != 0 || len(read.parts) != 0 || len(read.errors) != 0 {
		t.Errorf("got %+v", read)
	}
}

// Every part of build.yaml but a known builder's options is a part Gazelle
// cannot carry, named by its key path and the line of its key.
func TestBuilderOptionsRefusesTheRest(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true}
	read := builderOptions([]byte(`global_options:
  json_serializable:
    options: {}
targets:
  $default:
    sources: [lib/**]
    builders:
      json_serializable:
        generate_for: [lib/models/**]
        dev_options: {checked: true}
        options:
          checked: false
      build_web_compilers:entrypoint:
        options: {compiler: dart2wasm}
  other:
    builders: {}
`), known)
	want := []struct {
		path string
		line int
	}{
		{"global_options", 1},
		{"targets.$default.sources", 6},
		{"targets.$default.builders.json_serializable.generate_for", 9},
		{"targets.$default.builders.json_serializable.dev_options", 10},
		{"targets.$default.builders.build_web_compilers:entrypoint", 13},
		{"targets.other", 15},
	}
	if len(read.errors) != 0 {
		t.Fatalf("errors: %v", read.errors)
	}
	if len(read.parts) != len(want) {
		t.Fatalf("got %d parts, want %d: %v", len(read.parts), len(want), read.parts)
	}
	for i, w := range want {
		if got := read.parts[i]; got.path != w.path || got.line != w.line {
			t.Errorf("part %d = %s:%d, want %s:%d", i, got.path, got.line, w.path, w.line)
		}
	}
	if !strings.HasPrefix(read.parts[4].why, "names a builder") {
		t.Errorf("why = %q", read.parts[4].why)
	}
	// What can be carried still is.
	if got := read.cfgs["json_serializable:json_serializable"]; got != `{"checked":false}` {
		t.Errorf("options = %q", got)
	}
}

// Options reached through a YAML alias are carried as the node it names.
func TestBuilderOptionsAlias(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true}
	read := builderOptions([]byte(`
common: &common {checked: true}
targets:
  $default:
    builders:
      json_serializable:
        options: *common
`), known)
	if got := read.cfgs["json_serializable:json_serializable"]; got != `{"checked":true}` {
		t.Errorf("options = %q", got)
	}
	if len(read.parts) != 1 || read.parts[0].path != "common" {
		t.Errorf("parts = %v", read.parts)
	}
}

func TestBuilderOptionsTwice(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true}
	read := builderOptions([]byte(`
targets:
  $default:
    builders:
      json_serializable: {options: {a: 1}}
      json_serializable:json_serializable: {options: {a: 2}}
`), known)
	if len(read.errors) != 1 || !strings.Contains(read.errors[0], "a second time") || read.unread {
		t.Errorf("errors: %v", read.errors)
	}
}

func TestBuilderOptionsUnreadable(t *testing.T) {
	for _, src := range []string{"targets: [\n", "a: 1\na: 2\n", "- a\n"} {
		read := builderOptions([]byte(src), nil)
		if len(read.errors) != 1 || !read.unread {
			t.Errorf("%q: errors: %v", src, read.errors)
		}
	}
}

func TestNormalizeBuilderKey(t *testing.T) {
	for in, want := range map[string]string{
		"freezed":                      "freezed:freezed",
		"freezed:freezed":              "freezed:freezed",
		"freezed|freezed":              "freezed:freezed",
		"mockito:mockBuilder":          "mockito:mockBuilder",
		"source_gen|combining_builder": "source_gen:combining_builder",
	} {
		if got := normalizeBuilderKey(in); got != want {
			t.Errorf("normalizeBuilderKey(%q) = %q, want %q", in, got, want)
		}
	}
}

// Each shipped builder has a build.yaml key: every macro takes a `config`.
func TestDefaultBuildersHaveKeys(t *testing.T) {
	for _, b := range defaultBuilders() {
		if b.Key == "" {
			t.Errorf("%s (%s) has no build.yaml key", b.Annotation, b.ShimLabel)
		}
	}
}

func TestSameJSON(t *testing.T) {
	if !sameJSON(`{"a": 1, "b": [true]}`, `{"b":[true],"a":1}`) {
		t.Error("equal objects differ")
	}
	if sameJSON(`{"a": 1}`, `{"a": "1"}`) {
		t.Error("different objects agree")
	}
}
