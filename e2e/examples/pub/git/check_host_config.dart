// Run from the workspace root: `dart pub/git/check_host_config.dart`.
//
// Property: the host's git configuration reaches the fetch and nothing else.
// Each scenario runs `//pub/git:git_packages_test` in a fresh output base, with
// every repository fetched anew, for a host whose global config
//   * speaks protocol v0, whose servers refuse to fetch a commit no ref
//     advertises, so the two packages locked below a branch tip are reached
//     only by fetching every ref, and
//   * asks for line-ending conversion, a smudge filter on every file, no
//     symlinks, hooks, a template and SHA-256 repositories, any of which
//     changes the bytes the test checks, or breaks the fetch, if it applies.
//
// The scenarios differ in how the fetch reaches its remotes:
//   * `files`: the remotes are the relative paths the lock names.
//   * `config`: the lock names `ssh://git-fixture.invalid/`, a host that does
//     not exist, and only `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/
//     `GIT_CONFIG_VALUE_<n>` in the client's environment rewrite it
//     (`url.<base>.insteadOf`) to the remotes. The same variables also ask for
//     line-ending conversion, a smudge filter and no symlinks, which must not
//     reach the files.
//   * `ssh`: the same host, reachable only through `GIT_SSH_COMMAND`.
import 'dart:io';

typedef Scenario = ({String name, List<String> flags});

void main() {
  final temp = Directory.systemTemp.createTempSync('pub_lock_git_host_');
  final home = '${temp.path}/home';
  final remotes = '${temp.path}/remotes';
  Directory('$home/hooks').createSync(recursive: true);
  Directory('$home/template').createSync(recursive: true);
  Directory(remotes).createSync(recursive: true);
  File('$home/attributes').writeAsStringSync('* filter=evil\n');
  File('$home/.gitconfig').writeAsStringSync('''
[protocol]
	version = 0
[core]
	autocrlf = true
	eol = crlf
	symlinks = false
	attributesFile = $home/attributes
	hooksPath = $home/hooks
[filter "evil"]
	smudge = sed s/x/EVIL/
	clean = cat
[init]
	templateDir = $home/template
	defaultObjectFormat = sha256
''');

  // What git asks of an ssh host is `git-upload-pack '/<name>.git'`; the
  // command answers it from the remotes directory.
  final sshCommand =
      'sh -c \'cd "$remotes" && eval "\$(printf %s "\$2" | '
      r'sed "s,^git-upload-pack \(.\)/,git upload-pack \1,")"'
      "' --";
  final scenarios = <Scenario>[
    (name: 'files', flags: []),
    (
      name: 'config',
      flags: [
        '--repo_env=PUB_LOCK_GIT_REMOTES=$remotes',
        '--repo_env=GIT_CONFIG_COUNT=5',
        '--repo_env=GIT_CONFIG_KEY_0=url.file://$remotes/.insteadOf',
        '--repo_env=GIT_CONFIG_VALUE_0=ssh://git-fixture.invalid/',
        '--repo_env=GIT_CONFIG_KEY_1=core.autocrlf',
        '--repo_env=GIT_CONFIG_VALUE_1=true',
        '--repo_env=GIT_CONFIG_KEY_2=core.attributesFile',
        '--repo_env=GIT_CONFIG_VALUE_2=$home/attributes',
        '--repo_env=GIT_CONFIG_KEY_3=filter.evil.smudge',
        '--repo_env=GIT_CONFIG_VALUE_3=sed s/x/EVIL/',
        '--repo_env=GIT_CONFIG_KEY_4=core.symlinks',
        '--repo_env=GIT_CONFIG_VALUE_4=false',
      ],
    ),
    (
      name: 'ssh',
      flags: [
        '--repo_env=PUB_LOCK_GIT_REMOTES=$remotes',
        '--repo_env=GIT_SSH_COMMAND=$sshCommand',
      ],
    ),
  ];

  try {
    for (final scenario in scenarios) {
      final startup = [
        '--output_base=${temp.path}/output_base_${scenario.name}',
      ];
      try {
        final test = Process.runSync('bazel', [
          ...startup,
          'test',
          '//pub/git:git_packages_test',
          '--repo_env=HOME=$home',
          '--repo_contents_cache=',
          '--test_output=errors',
          // This run's temp paths must not reach the committed
          // MODULE.bazel.lock.
          '--lockfile_mode=off',
          ...scenario.flags,
        ]);
        stdout.write(test.stdout);
        stderr.write(test.stderr);
        if (test.exitCode != 0) {
          stderr.writeln(
            'FAILED (${scenario.name}): the host changed the fetch',
          );
          exitCode = 1;
        }
      } finally {
        Process.runSync('bazel', [...startup, 'shutdown']);
      }
    }
  } finally {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  }
}
