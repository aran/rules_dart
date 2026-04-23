package dart

import (
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

func TestFilterOutGeneratedFiles(t *testing.T) {
	registry := registryWith(&builderInfo{
		Annotation: "X",
		Produces:   []string{".x.g.part"},
	})
	in := []DartFileInfo{
		{Path: "lib/user.dart"},
		{Path: "lib/user.g.dart"},
		{Path: "lib/user.x.g.part"},
		{Path: "lib/user.freezed.dart"},
		{Path: "lib/user.mocks.dart"},
	}
	out := filterOutGeneratedFiles(in, registry)
	if len(out) != 1 || out[0].Path != "lib/user.dart" {
		t.Fatalf("filter dropped wrong files: %#v", out)
	}
}

func TestDefaultBuildersIncludesShipped(t *testing.T) {
	r := &builderRegistry{byAnnotation: map[string][]*builderInfo{}}
	for _, b := range defaultBuilders() {
		r.byAnnotation[b.Annotation] = append(r.byAnnotation[b.Annotation], b)
	}
	for _, want := range []string{
		"JsonSerializable", "freezed", "Freezed", "CopyWith",
		"GenerateMocks", "TypedGoRoute", "InjectableInit",
		"DriftDatabase", "StackedApp", "FormView",
	} {
		if r.lookup(want) == nil {
			t.Errorf("default registry missing %s", want)
		}
	}
	// @StackedApp must fan out to exactly five builders (router, locator,
	// logger, dialog, bottomsheet — form uses @FormView separately).
	got := len(r.lookup("StackedApp"))
	if got != 5 {
		t.Errorf("@StackedApp should register 5 sub-builders, got %d", got)
	}
}

// TestAllRegisteredProducedExtensionsSorted verifies the returned slice
// is lexicographically sorted so downstream consumers (Gazelle's
// generated-file filter) don't depend on Go's randomised map iteration.
func TestAllRegisteredProducedExtensionsSorted(t *testing.T) {
	r := registryWith(
		&builderInfo{Annotation: "Z", Produces: []string{".zzz.g.part"}},
		&builderInfo{Annotation: "A", Produces: []string{".aaa.g.part"}},
		&builderInfo{Annotation: "M", Produces: []string{".mmm.g.part", ".more.g.part"}},
	)
	got := r.allRegisteredProducedExtensions()
	for i := 1; i < len(got); i++ {
		if got[i] < got[i-1] {
			t.Fatalf("extensions not sorted: %v", got)
		}
	}
}
