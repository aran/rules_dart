package dart

import (
	"reflect"
	"testing"
)

func TestStageTargetName(t *testing.T) {
	jsonInfo := &builderInfo{
		Annotation: "JsonSerializable",
		Produces:   []string{".json_serializable.g.part"},
	}
	freezedInfo := &builderInfo{
		Annotation: "Freezed",
		Produces:   []string{".freezed.dart"},
	}
	routerInfo := &builderInfo{
		Annotation: "StackedApp",
		Produces:   []string{".router.dart"},
	}
	locatorInfo := &builderInfo{
		Annotation: "StackedApp",
		Produces:   []string{".locator.dart"},
	}
	tests := []struct {
		name   string
		src    string
		stage  pipelineStage
		fanOut bool
		want   string
	}{
		{
			name:  "JsonSerializable (no fan-out)",
			src:   "lib/user.dart",
			stage: pipelineStage{Builder: jsonInfo, ID: nodeKey(jsonInfo)},
			want:  "_user_json_serializable_gen",
		},
		{
			name:  "freezed (no fan-out)",
			src:   "lib/event.dart",
			stage: pipelineStage{Builder: freezedInfo, ID: nodeKey(freezedInfo)},
			want:  "_event_freezed_gen",
		},
		{
			name:  "combining stage",
			src:   "lib/user.dart",
			stage: pipelineStage{Combining: true},
			want:  "_user_combined",
		},
		{
			name: "stacked router fan-out gets distinct name from locator",
			src:  "lib/app.dart",
			stage: pipelineStage{
				Builder: routerInfo,
				ID:      nodeKey(routerInfo),
			},
			fanOut: true,
			want:   "_app_stacked_app_router_gen",
		},
		{
			name: "stacked locator fan-out",
			src:  "lib/app.dart",
			stage: pipelineStage{
				Builder: locatorInfo,
				ID:      nodeKey(locatorInfo),
			},
			fanOut: true,
			want:   "_app_stacked_app_locator_gen",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := stageTargetName(tt.src, tt.stage, tt.fanOut)
			if got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestPackageReach(t *testing.T) {
	rel := func(uri string) DartImport { return DartImport{URI: uri, IsRelative: true} }
	pkg := func(p, path string) DartImport {
		return DartImport{URI: "package:" + p + "/" + path, IsPackage: true, Package: p, Path: path}
	}
	lib := []DartFileInfo{
		// A plain file and an annotated one importing each other.
		{Path: "p/lib/p.dart", Imports: []DartImport{rel("user.dart"), rel("src/helper.dart")}},
		{Path: "p/lib/user.dart", Imports: []DartImport{rel("p.dart"), pkg("json_annotation", "json_annotation.dart")}},
		{Path: "p/lib/src/helper.dart", Imports: []DartImport{pkg("p", "src/deep.dart"), pkg("other", "o.dart")}},
		{Path: "p/lib/src/deep.dart"},
		{Path: "p/lib/unreached.dart"},
	}
	reach := packageReach(lib, "p", "p")
	var got []string
	for _, f := range reach("p/lib/user.dart") {
		got = append(got, f.Path)
	}
	want := []string{"p/lib/p.dart", "p/lib/src/deep.dart", "p/lib/src/helper.dart"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("reach(user.dart) = %v, want %v", got, want)
	}
	if got := reach("p/lib/src/deep.dart"); len(got) != 0 {
		t.Errorf("reach(deep.dart) = %v, want none", got)
	}
}

func TestRunsBefore(t *testing.T) {
	freezed := &builderInfo{Annotation: "Freezed", Produces: []string{".freezed.dart"}, Consumes: []string{".dart"}, RunsBefore: []string{"JsonSerializable"}}
	json := &builderInfo{Annotation: "JsonSerializable", Produces: []string{".json_serializable.g.part"}, Consumes: []string{".dart"}, RunsBefore: []string{"Late"}}
	late := &builderInfo{Annotation: "Late", Produces: []string{".late.dart"}, Consumes: []string{".dart"}}
	other := &builderInfo{Annotation: "Other", Produces: []string{".other.dart"}, Consumes: []string{".dart"}}
	r := registryWith(freezed, json, late, other)
	for _, tt := range []struct {
		a, b *builderInfo
		want bool
	}{
		{freezed, json, true},
		{freezed, late, true}, // through json_serializable
		{json, freezed, false},
		{freezed, freezed, false},
		{freezed, other, false},
		{other, json, false},
	} {
		if got := r.runsBefore(tt.a, tt.b); got != tt.want {
			t.Errorf("runsBefore(%s, %s) = %v, want %v", tt.a.Annotation, tt.b.Annotation, got, tt.want)
		}
	}
}
