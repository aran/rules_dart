"""Unit tests for `dependency_cycle` in dart/pub/private/pub_graph.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:pub_graph.bzl", "dependency_cycle")
load(":small_suite.bzl", "small_unittest_suite")

def _acyclic_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = {"a": ["b", "c"], "b": ["c"], "c": []}
    asserts.equals(env, ["a"], dependency_cycle(graph, "a"))
    asserts.equals(env, ["c"], dependency_cycle(graph, "c"))
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
    asserts.equals(env, ["dio", "dio_web_adapter"], dependency_cycle(graph, "dio"))
    asserts.equals(env, ["dio", "dio_web_adapter"], dependency_cycle(graph, "dio_web_adapter"))
    asserts.equals(env, ["http"], dependency_cycle(graph, "http"))
    asserts.equals(env, ["meta"], dependency_cycle(graph, "meta"))
    return unittest.end(env)

def _long_cycle_with_tail_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = {"a": ["b"], "b": ["c"], "c": ["a", "d"], "d": ["e"], "e": ["d"]}
    asserts.equals(env, ["a", "b", "c"], dependency_cycle(graph, "b"))
    asserts.equals(env, ["d", "e"], dependency_cycle(graph, "e"))
    return unittest.end(env)

def _self_and_unknown_edges_test_impl(ctx):
    env = unittest.begin(ctx)

    # An edge to a name outside the graph (a package declared elsewhere) is a
    # dead end, and a package naming itself is no cycle of several.
    graph = {"a": ["a", "elsewhere"]}
    asserts.equals(env, ["a"], dependency_cycle(graph, "a"))
    return unittest.end(env)

_t0_test = unittest.make(_acyclic_test_impl)
_t1_test = unittest.make(_two_cycle_test_impl)
_t2_test = unittest.make(_long_cycle_with_tail_test_impl)
_t3_test = unittest.make(_self_and_unknown_edges_test_impl)

def pub_graph_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
