package dart

import (
	"fmt"
	"sort"
)

// pipelineStage represents one rule the DAG-emitter will produce: a
// single dart_codegen or combining_shim invocation operating on one input
// source.
type pipelineStage struct {
	// Builder is the registered builder driving this stage. Nil for the
	// synthetic combining stage.
	Builder *builderInfo
	// Combining is true for the synthetic .g.part → .g.dart merge stage.
	Combining bool
	// OutputExts is the list of extensions this stage emits, in the order
	// declared by the builder's `Produces` (or `[".g.dart"]` for
	// combining). The rule layer sets `output_suffixes=[...]` to this.
	OutputExts []string
	// PartShards lists prior-stage IDs whose `.g.part` outputs this
	// combining stage merges. Empty for non-combining stages.
	PartShards []string
	// After lists the IDs of the prior stages this one has an edge from:
	// the builders whose outputs it reads (consumes/produces) or that must
	// run before it (runs_before). Empty for the combining stage.
	After []string
	// ID is the unique node ID of this stage within the pipeline graph.
	// Non-combining stages use `(annotation, primary-produced-ext)` to
	// disambiguate multiple builders that watch the same annotation
	// (e.g. @StackedApp fans out to five). Combining stages use
	// `__combining`.
	ID string
}

// buildPipelineForFile orders every registered builder applicable to the
// file's annotations into a deterministic pipeline of stages, plus a
// combining stage when one or more SharedPart shards are emitted. Returns
// an error on cycles or genuinely-conflicting `runs_before` constraints.
//
// Multiple builders can watch the same annotation (e.g. @StackedApp fans
// out to five sub-builders). Nodes are keyed on `(annotation,
// primary-produced-ext)` so each sub-builder is a distinct node.
func buildPipelineForFile(
	annotations []string,
	registry *builderRegistry,
) ([]pipelineStage, error) {
	var nodes []*builderInfo
	seenAnnotation := map[string]struct{}{}
	for _, a := range annotations {
		if _, ok := seenAnnotation[a]; ok {
			continue
		}
		seenAnnotation[a] = struct{}{}
		for _, info := range registry.lookup(a) {
			nodes = append(nodes, info)
		}
	}
	// Dedupe nodes by (annotation, shim label, primary produced extension).
	seenNode := map[string]struct{}{}
	deduped := nodes[:0]
	for _, n := range nodes {
		key := nodeKey(n)
		if _, ok := seenNode[key]; ok {
			continue
		}
		seenNode[key] = struct{}{}
		deduped = append(deduped, n)
	}
	nodes = deduped

	if len(nodes) == 0 {
		return nil, nil
	}

	// Topological sort. Edges: A → B means A must run before B (precedes).
	indegree := map[string]int{}
	adj := map[string][]string{}
	preds := map[string][]string{}
	byID := map[string]*builderInfo{}
	type edge struct{ from, to string }
	seenEdge := map[edge]bool{}
	for _, n := range nodes {
		id := nodeKey(n)
		byID[id] = n
		indegree[id] = 0
	}

	addEdge := func(fromID, toID string) {
		if _, ok := byID[fromID]; !ok {
			return
		}
		if _, ok := byID[toID]; !ok {
			return
		}
		if fromID == toID {
			return
		}
		e := edge{fromID, toID}
		if seenEdge[e] {
			return
		}
		seenEdge[e] = true
		adj[fromID] = append(adj[fromID], toID)
		preds[toID] = append(preds[toID], fromID)
		indegree[toID]++
	}

	for _, a := range nodes {
		for _, b := range nodes {
			if precedes(a, b) {
				addEdge(nodeKey(a), nodeKey(b))
			}
		}
	}

	var orderIDs []string
	queue := []string{}
	for _, n := range nodes {
		if indegree[nodeKey(n)] == 0 {
			queue = append(queue, nodeKey(n))
		}
	}
	sort.Strings(queue) // deterministic

	for len(queue) > 0 {
		head := queue[0]
		queue = queue[1:]
		orderIDs = append(orderIDs, head)
		children := append([]string(nil), adj[head]...)
		sort.Strings(children)
		for _, c := range children {
			indegree[c]--
			if indegree[c] == 0 {
				queue = append(queue, c)
			}
		}
	}

	if len(orderIDs) != len(nodes) {
		return nil, fmt.Errorf("cycle detected in dart_builder pipeline for annotations %v", annotations)
	}

	// Build per-builder stages, plus a combining stage if any SharedPart
	// shards were emitted.
	var stages []pipelineStage
	var partShards []string
	for _, id := range orderIDs {
		b := byID[id]
		stages = append(stages, pipelineStage{
			Builder:    b,
			OutputExts: append([]string(nil), b.Produces...),
			After:      sortedCopy(preds[id]),
			ID:         id,
		})
		if b.SharedPart {
			partShards = append(partShards, id)
		}
	}
	if len(partShards) > 0 {
		stages = append(stages, pipelineStage{
			Combining:  true,
			OutputExts: []string{".g.dart"},
			PartShards: partShards,
			ID:         "__combining",
		})
	}
	return stages, nil
}

// nodeKey returns the unique DAG-node ID for a builder: the annotation
// plus the primary produced extension. Two builders watching the same
// annotation (e.g. @StackedApp's five sub-builders) get distinct IDs
// because each produces a different extension.
func nodeKey(b *builderInfo) string {
	primary := ""
	if len(b.Produces) > 0 {
		primary = b.Produces[0]
	}
	return b.Annotation + "|" + primary
}

func sortedCopy(s []string) []string {
	if len(s) == 0 {
		return nil
	}
	out := append([]string(nil), s...)
	sort.Strings(out)
	return out
}

// precedes reports whether builder a runs directly before builder b: b
// consumes an extension a produces, or a's `runs_before` names b's
// annotation.
func precedes(a, b *builderInfo) bool {
	if nodeKey(a) == nodeKey(b) {
		return false
	}
	for _, p := range a.Produces {
		for _, c := range b.Consumes {
			if p == c {
				return true
			}
		}
	}
	for _, ann := range a.RunsBefore {
		if ann == b.Annotation {
			return true
		}
	}
	return false
}

// runsBefore reports whether builder a runs before builder b, directly or
// through others, among the registered builders: what a writes for a
// source is there when b runs on any source, as build_runner's earlier
// phases are for its later ones.
func (r *builderRegistry) runsBefore(a, b *builderInfo) bool {
	var all []*builderInfo
	for _, ann := range sortedKeys(r.byAnnotation) {
		all = append(all, r.byAnnotation[ann]...)
	}
	seen := map[string]bool{}
	var visit func(x *builderInfo) bool
	visit = func(x *builderInfo) bool {
		for _, y := range all {
			if seen[nodeKey(y)] || !precedes(x, y) {
				continue
			}
			if nodeKey(y) == nodeKey(b) {
				return true
			}
			seen[nodeKey(y)] = true
			if visit(y) {
				return true
			}
		}
		return false
	}
	return visit(a)
}
