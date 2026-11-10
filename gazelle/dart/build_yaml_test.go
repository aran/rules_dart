package dart

import (
	"reflect"
	"strings"
	"testing"
)

func TestBuilderOptionsCarriesOptions(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true, "freezed:freezed": true}
	cfgs, problems := builderOptions([]byte(`
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
	if len(problems) != 0 {
		t.Fatalf("problems: %v", problems)
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
	cfgs, problems := builderOptions([]byte("# nothing\n"), nil)
	if len(cfgs) != 0 || len(problems) != 0 {
		t.Errorf("got %v, %v", cfgs, problems)
	}
}

// Every part of build.yaml but a known builder's options is a problem, named
// by its path.
func TestBuilderOptionsRefusesTheRest(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true}
	cfgs, problems := builderOptions([]byte(`
global_options:
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
	want := []string{
		"`global_options`",
		"`targets.$default.builders.build_web_compilers:entrypoint` names a builder",
		"`targets.$default.builders.json_serializable.dev_options`",
		"`targets.$default.builders.json_serializable.generate_for`",
		"`targets.$default.sources`",
		"`targets.other`",
	}
	if len(problems) != len(want) {
		t.Fatalf("got %d problems, want %d: %v", len(problems), len(want), problems)
	}
	for _, w := range want {
		found := false
		for _, p := range problems {
			if strings.HasPrefix(p, w) {
				found = true
			}
		}
		if !found {
			t.Errorf("no problem starts with %s: %v", w, problems)
		}
	}
	// What can be carried still is.
	if got := cfgs["json_serializable:json_serializable"]; got != `{"checked":false}` {
		t.Errorf("options = %q", got)
	}
}

func TestBuilderOptionsTwice(t *testing.T) {
	known := map[string]bool{"json_serializable:json_serializable": true}
	_, problems := builderOptions([]byte(`
targets:
  $default:
    builders:
      json_serializable: {options: {a: 1}}
      json_serializable:json_serializable: {options: {a: 2}}
`), known)
	if len(problems) != 1 || !strings.Contains(problems[0], "a second time") {
		t.Errorf("problems: %v", problems)
	}
}

func TestBuilderOptionsUnreadable(t *testing.T) {
	_, problems := builderOptions([]byte("targets: [\n"), nil)
	if len(problems) != 1 || !strings.HasPrefix(problems[0], "cannot be read") {
		t.Errorf("problems: %v", problems)
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
