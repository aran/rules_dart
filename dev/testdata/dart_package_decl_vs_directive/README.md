# dart_package_decl_vs_directive

A `# gazelle:dart_package_name` directive and a `dart_package_metadata` in the
same directory whose `package_name`, marked `# keep`, names a different
package. Gazelle leaves a `# keep` attribute as it is, so the build would carry
the difference: one fact stated twice must agree, so Gazelle fails, naming both
values and where each is stated, and writes no BUILD file. Without `# keep`,
Gazelle rewrites the metadata's name from the directive.
