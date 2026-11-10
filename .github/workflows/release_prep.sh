#!/usr/bin/env bash
# Called by bazel-contrib's release_ruleset workflow with the tag; what it
# prints becomes the release notes. See overhead/release/prep.dart.
set -o errexit -o nounset -o pipefail

bazel run --noshow_progress --ui_event_filters=-info @overhead//release:prep -- "$1"

# Generated API docs for the release, see https://github.com/bazelbuild/bazel-central-registry/issues/5593
docs="$(mktemp -d)"; targets="$(mktemp)"
bazel --output_base="$docs" query --output=label --output_file="$targets" 'kind("starlark_doc_extract rule", //...)'
bazel --output_base="$docs" build --target_pattern_file="$targets"
tar --create --auto-compress \
    --directory "$(bazel --output_base="$docs" info bazel-bin)" \
    --file "$GITHUB_WORKSPACE/rules_dart-$1.docs.tar.gz" .
