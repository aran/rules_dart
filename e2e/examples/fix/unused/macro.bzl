"""A macro that hands one `deps` to two targets, as a test macro does."""

load("@rules_dart//dart:defs.bzl", "dart_library")

def two_programs(name, **kwargs):
    dart_library(name = name + ".program", **kwargs)
    dart_library(name = name + "_copy.program", **kwargs)
