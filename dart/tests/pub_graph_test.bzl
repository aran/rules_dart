"""Unit tests for `dependency_graph` and `dependency_cycle` in dart/pub/pub_graph.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pub_graph.bzl", "dependency_cycle", "dependency_graph")
load(":small_suite.bzl", "small_unittest_suite")

def _acyclic_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = {"a": ["b", "c"], "b": ["c"], "c": []}
    asserts.equals(env, ["a"], dependency_cycle(graph, "a").packages)
    asserts.equals(env, ["c"], dependency_cycle(graph, "c").packages)
    return unittest.end(env)

def _two_cycle_test_impl(ctx):
    env = unittest.begin(ctx)

    # dio <-> dio_web_adapter, both on meta, and http on dio.
    graph = {
        "dio": ["dio_web_adapter", "meta"],
        "dio_web_adapter": ["dio", "meta"],
        "meta": [],
        "http": ["dio"],
    }
    asserts.equals(env, ["dio", "dio_web_adapter"], dependency_cycle(graph, "dio").packages)
    asserts.equals(env, ["dio", "dio_web_adapter"], dependency_cycle(graph, "dio_web_adapter").packages)
    asserts.equals(env, ["http"], dependency_cycle(graph, "http").packages)
    asserts.equals(env, ["meta"], dependency_cycle(graph, "meta").packages)
    return unittest.end(env)

def _long_cycle_with_tail_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = {"a": ["b"], "b": ["c"], "c": ["a", "d"], "d": ["e"], "e": ["d"]}
    asserts.equals(env, ["a", "b", "c"], dependency_cycle(graph, "b").packages)
    asserts.equals(env, ["d", "e"], dependency_cycle(graph, "e").packages)
    return unittest.end(env)

def _self_and_unknown_edges_test_impl(ctx):
    env = unittest.begin(ctx)

    # An edge to a name outside the graph (a package declared elsewhere) is a
    # dead end, and a package naming itself is no cycle of several.
    graph = {"a": ["a", "elsewhere"]}
    cycle = dependency_cycle(graph, "a")
    asserts.equals(env, ["a"], cycle.packages)
    asserts.equals(env, ["elsewhere"], cycle.deps)
    return unittest.end(env)

def _owner_and_deps_test_impl(ctx):
    env = unittest.begin(ctx)

    # The cycle's first package by name builds it, and the cycle depends on
    # the union of what its packages depend on outside it, edges to packages
    # absent from the graph included.
    graph = {
        "dio_web_adapter": ["dio", "web", "meta"],
        "dio": ["dio_web_adapter", "meta", "elsewhere"],
        "meta": [],
        "web": [],
    }
    cycle = dependency_cycle(graph, "dio_web_adapter")
    asserts.equals(env, "dio", cycle.owner)
    asserts.equals(env, ["elsewhere", "meta", "web"], cycle.deps)
    asserts.equals(env, [], dependency_cycle(graph, "meta").deps)
    return unittest.end(env)

def _graph_walk_test_impl(ctx):
    env = unittest.begin(ctx)
    edges = {
        "a": ["b", "declared"],
        "b": ["a", "c"],
        "c": [],
        "declared": ["unreached"],
        "unrelated": ["a"],
    }
    asked = []

    def dependencies(p):
        asked.append(p)
        return edges[p]

    # Followed packages are read once each; a package outside `follow` is a
    # leaf whose dependencies are never asked for; nothing unreached is read.
    graph = dependency_graph("a", dependencies, follow = {"a": True, "b": True, "c": True, "unrelated": True})
    asserts.equals(env, {"a": ["b", "declared"], "b": ["a", "c"], "c": []}, graph)
    asserts.equals(env, ["a", "b", "c"], sorted(asked))
    return unittest.end(env)

_t0_test = unittest.make(_acyclic_test_impl)
_t1_test = unittest.make(_two_cycle_test_impl)
_t2_test = unittest.make(_long_cycle_with_tail_test_impl)
_t3_test = unittest.make(_self_and_unknown_edges_test_impl)
_t4_test = unittest.make(_owner_and_deps_test_impl)
_t5_test = unittest.make(_graph_walk_test_impl)

def pub_graph_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
