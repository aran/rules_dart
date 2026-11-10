Test that each `dart_test` carries its file's package:test suite tags
(`@Tags([...])` on the first directive) as Bazel `tags`, in every form
package:test reads, and that tags Gazelle cannot or must not copy (a const
variable, a name Bazel gives meaning to) are reported, not guessed or passed
through.
