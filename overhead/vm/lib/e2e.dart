/// Runs a repository's e2e suites on a VM `create_vm.dart` made.
///
/// A repository runs it from a `dart_binary` of its own, which passes
/// [runE2e] what to run (its [E2eItem]s, from whatever table of its own says
/// what CI runs) and, if it needs them, setup steps and options of its own.
/// The runner packages the committed tree, waits for the VM's toolchain,
/// copies the tree over, writes the VM's home bazelrc, runs the setup, runs
/// each item in its folder, and prints a PASS/FAIL summary, exiting non-zero
/// when anything failed.
///
/// Its command line:
///
///     <vm-name> [--windows] [--folders=a,b] [--keep-going]
///         [--remote-cache=<url>]
///
/// and the repository's own `--name=value` options ([runE2e]'s `options`).
library;

import 'dart:async';
import 'dart:io';

import 'create_vm.dart' show waitForWindowsStartup;
import 'gcloud.dart';

/// One thing to run on the VM: Bazel or a script in a folder of the checkout,
/// and the exit codes that pass.
final class E2eItem {
  /// `bazel <args>` in [folder]. On Windows it gets an output base of its own
  /// under `C:/b`, short enough for MAX_PATH.
  E2eItem.bazel(
    this.folder,
    List<String> this.bazelArgs, {
    String? name,
    this.passExitCodes = const {0},
    this.timeout = defaultItemTimeout,
  }) : script = null,
       name = name ?? folder;

  /// A bash [script] run in [folder] as a GitHub Actions `run` step is
  /// (`bash -e -o pipefail`). Linux only.
  E2eItem.script(
    this.folder,
    String this.script, {
    String? name,
    this.passExitCodes = const {0},
    this.timeout = defaultItemTimeout,
  }) : bazelArgs = null,
       name = name ?? folder;

  /// The folder to run in, relative to the checkout root; `.` is the root.
  final String folder;

  /// What the summary calls it.
  final String name;

  final List<String>? bazelArgs;
  final String? script;

  /// The exit codes that pass: `{0, 4}` where finding no test target is fine.
  final Set<int> passExitCodes;

  /// How long it may run before it fails as timed out and its folder's Bazel
  /// server is stopped ([stopCommand]).
  final Duration timeout;
}

/// The runner's command line.
final class E2eOptions {
  E2eOptions({
    required this.vm,
    this.windows = false,
    this.keepGoing = false,
    this.remoteCache,
    this.folders,
    this.repoOptions = const {},
  });

  /// Parses [args]. [repoOptions] names the repository's own
  /// `--<name>=<value>` options. Throws [FormatException].
  factory E2eOptions.parse(
    List<String> args, {
    Set<String> repoOptions = const {},
  }) {
    final positional = <String>[];
    var windows = false;
    var keepGoing = false;
    String? remoteCache;
    List<String>? folders;
    final repo = <String, String>{};
    for (final arg in args) {
      final eq = arg.indexOf('=');
      final name = eq < 0 ? arg : arg.substring(0, eq);
      final value = eq < 0 ? null : arg.substring(eq + 1);
      String needValue() =>
          value ?? (throw FormatException('$name needs a value: $name=...'));
      switch (name) {
        case '--windows' when value == null:
          windows = true;
        case '--keep-going' when value == null:
          keepGoing = true;
        case '--remote-cache':
          remoteCache = needValue();
        case '--folders':
          folders = [
            for (final f in needValue().split(','))
              if (f.trim().isNotEmpty) _normalize(f.trim()),
          ];
        case _
            when name.startsWith('--') &&
                repoOptions.contains(name.substring(2)):
          repo[name.substring(2)] = needValue();
        case _ when arg.startsWith('-'):
          throw FormatException('unknown option $arg');
        default:
          positional.add(arg);
      }
    }
    if (positional.length != 1) {
      throw FormatException(
        positional.isEmpty
            ? 'no VM named'
            : 'one VM name, not ${positional.join(' ')}',
      );
    }
    return E2eOptions(
      vm: positional.single,
      windows: windows,
      keepGoing: keepGoing,
      remoteCache: remoteCache,
      folders: folders,
      repoOptions: repo,
    );
  }

  final String vm;
  final bool windows;

  /// Run every item even after one fails.
  final bool keepGoing;

  /// A Bazel remote cache the VMs share, such as a GCS bucket
  /// (`https://storage.googleapis.com/<bucket>`) their service account may
  /// write.
  final String? remoteCache;

  /// The folders `--folders=` names, or null to run what CI runs.
  final List<String>? folders;

  /// The repository's own options that were given, by name.
  final Map<String, String> repoOptions;
}

/// The VM a run is on, for a repository's setup steps.
final class E2eVm {
  E2eVm(this.name, {required this.windows, required String repo})
    : checkout = windows ? 'C:\\src\\$repo' : '\$HOME/src/$repo';

  final String name;
  final bool windows;

  /// The checkout's path on the VM: `C:\src\<repo>` on Windows,
  /// `$HOME/src/<repo>` (for a shell to expand) on Linux.
  final String checkout;

  /// Runs [command] over SSH, returning its stdout; throws on failure.
  Future<String> run(String command) => sshRun(name, command);

  /// Runs [command] over SSH and returns its result without throwing.
  Future<ProcessResult> exec(String command, {Duration? timeout}) =>
      ssh(name, command, timeout: timeout);

  Future<void> copyTo(String local, String remote, {bool compress = false}) =>
      scpToVm(name, local, remote, compress: compress);

  Future<void> copyFrom(String remote, String local, {bool compress = false}) =>
      scpFromVm(name, remote, local, compress: compress);
}

/// How long an item may run unless it says otherwise. The first item in a
/// fresh VM pays for fetching every toolchain and dependency.
const defaultItemTimeout = Duration(minutes: 30);

/// Runs the e2e suites on the VM [args] names, and exits.
///
/// [repo] names the checkout on the VM. [items] returns what to run, given
/// the parsed options and the local checkout's root. [setup] runs after the
/// tree and the bazelrc are on the VM and before the first item. [options]
/// maps each of the repository's own `--<name>=<value>` options to a line of
/// help; [usage] says what the repository's tool runs by default.
Future<Never> runE2e(
  List<String> args, {
  required String repo,
  required FutureOr<List<E2eItem>> Function(E2eOptions options, String root)
  items,
  Future<void> Function(E2eVm vm, E2eOptions options)? setup,
  Map<String, String> options = const {},
  String usage = '',
}) async {
  final E2eOptions parsed;
  try {
    parsed = E2eOptions.parse(args, repoOptions: options.keys.toSet());
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${_usage(options, usage)}');
    exit(2);
  }
  final root = checkoutRoot();
  final toRun = await items(parsed, root);
  if (toRun.isEmpty) {
    stderr.writeln('Nothing to run.');
    exit(2);
  }
  if (parsed.windows) {
    final scripts = [
      for (final item in toRun)
        if (item.script != null) item.name,
    ];
    if (scripts.isNotEmpty) {
      stderr.writeln('Scripts run on Linux only: ${scripts.join(', ')}');
      exit(2);
    }
  }
  final vm = E2eVm(parsed.vm, windows: parsed.windows, repo: repo);

  final tmp = Directory.systemTemp.createTempSync('e2e_');
  try {
    final tar = packageCommittedTree(root, tmp.path);
    await _waitForToolchain(vm);
    await _transfer(vm, tar, repo);
    final rc = File('${tmp.path}/bazelrc')
      ..writeAsStringSync(
        homeBazelrc(windows: vm.windows, remoteCache: parsed.remoteCache),
      );
    if (vm.windows) {
      await vm.copyTo(rc.path, 'C:/e2e_bazelrc');
      await vm.run(r'cmd /c copy /y C:\e2e_bazelrc "%USERPROFILE%\.bazelrc"');
    } else {
      await vm.copyTo(rc.path, '~/.bazelrc');
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }
  if (setup != null) await setup(vm, parsed);

  final results = <_Result>[];
  String? stopped;
  for (final item in toRun) {
    stdout.writeln('\n=== ${item.name} ===');
    final r = await ssh(
      vm.name,
      vm.windows
          ? windowsCommand(item, vm.checkout)
          : linuxCommand(item, vm.checkout),
      timeout: item.timeout,
    );
    if (r.exitCode == sshTimedOut) {
      // The SSH client is gone, but the build goes on: stop it, or it
      // competes with the next item for the VM.
      final stop = await vm.exec(
        stopCommand(item, vm.checkout, windows: vm.windows),
        timeout: const Duration(minutes: 2),
      );
      stdout.writeln(
        stop.exitCode == 0
            ? 'Stopped ${item.name}\'s Bazel server.'
            : 'Could not stop ${item.name}\'s Bazel server: ${stop.stderr}',
      );
    }
    final code = r.exitCode == sshTimedOut
        ? sshTimedOut
        : parseExit('${r.stdout}');
    final result = _Result(
      item,
      code,
      item.passExitCodes.contains(code),
      code == sshTimedOut
          ? 'TIMEOUT after ${item.timeout}'
          : tail('${r.stdout}\n${r.stderr}'),
    );
    results.add(result);
    stdout.writeln(
      '${result.pass ? 'PASS' : 'FAIL'} ${item.name} (exit $code)',
    );
    if (code == noExitMark) {
      final status = await instanceStatus(vm.name);
      if (status != 'RUNNING') {
        stopped =
            '${vm.name} is ${status ?? 'gone'}: a SPOT VM was probably '
            'preempted. With --remote-cache, a new VM reuses what this one '
            'built.';
        break;
      }
    }
    if (!result.pass && !parsed.keepGoing) {
      stopped = 'Stopped after a failure (--keep-going runs the rest).';
      break;
    }
  }

  stdout.writeln(
    '\n========== SUMMARY (${vm.windows ? 'windows' : 'linux'}) ==========',
  );
  for (final r in results) {
    stdout.writeln('  ${r.pass ? 'PASS' : 'FAIL'}  ${r.item.name}');
  }
  for (final item in toRun.skip(results.length)) {
    stdout.writeln('  ----  ${item.name} (not run)');
  }
  if (stopped != null) stdout.writeln('\n$stopped');
  final failed = results.where((r) => !r.pass).toList();
  if (failed.isEmpty && results.length == toRun.length) {
    stdout.writeln('\nAll ${results.length} passed.');
    exit(0);
  }
  stdout.writeln('\n${failed.length} FAILED:');
  for (final r in failed) {
    stdout
      ..writeln('\n----- ${r.item.name} (exit ${r.exitCode}) -----')
      ..writeln(r.tail);
  }
  exit(1);
}

/// The VM's home bazelrc, which every workspace's Bazel reads:
///
/// - one disk cache for all workspaces, so each reuses the tools the first
///   one built, bounded to fit the boot disk;
/// - an idle timeout and a heap cap, so each workspace's server exits once
///   done and none takes a quarter of the VM's memory;
/// - `--keep_going`, so a run reports every failure in a workspace, as CI's
///   does;
/// - with [remoteCache], a remote cache besides the disk cache, which VMs
///   running in parallel share, and which outlives a preempted VM.
String homeBazelrc({required bool windows, String? remoteCache}) => [
  'startup --max_idle_secs=900',
  'startup --host_jvm_args=-Xmx4g',
  // Bazel expands a leading `~/`.
  'common --disk_cache=${windows ? 'C:/bdc' : '~/.cache/bazel-disk'}',
  'common --experimental_disk_cache_gc_max_size=${windows ? '40G' : '20G'}',
  'common --experimental_disk_cache_gc_max_age=7d',
  'common --keep_going',
  if (remoteCache != null) ...[
    'common --remote_cache=$remoteCache',
    'common --google_default_credentials',
  ],
  '',
].join('\n');

/// The mark each item's command prints with its exit code.
const _exitMark = 'E2E_EXIT=';

/// What [parseExit] returns when the output has no exit mark: the SSH session
/// ended before the command did.
const noExitMark = -1;

/// The exit code [linuxCommand] or [windowsCommand] printed in [stdout].
int parseExit(String stdout) {
  final m = RegExp('$_exitMark(-?\\d+)').allMatches(stdout).lastOrNull;
  return m == null ? noExitMark : int.parse(m[1]!);
}

/// The command that runs [item] on a Linux VM whose checkout is at
/// [checkout]. The script crosses the SSH command line as base64.
String linuxCommand(E2eItem item, String checkout) {
  final script =
      item.script ?? 'bazel ${item.bazelArgs!.map(shellQuote).join(' ')}';
  final dir = item.folder == '.' ? checkout : '$checkout/${item.folder}';
  return "bash -lc 'cd \"$dir\" && "
      'echo ${base64Word(script)} | base64 -d > /tmp/e2e_step.sh && '
      "bash -e -o pipefail /tmp/e2e_step.sh; echo $_exitMark\$?'";
}

/// The command that runs [item], which must be Bazel, on a Windows VM whose
/// checkout is at [checkout].
///
/// `/v:on` makes `!errorlevel!` Bazel's exit, not its value when cmd parsed
/// the line. Each folder's output base is `C:/b/<hash of the folder>`: short,
/// so runfiles and generated paths stay under MAX_PATH (`--output_user_root`
/// would add a 32-character directory), and the same on the next run, so a
/// rerun is incremental.
String windowsCommand(E2eItem item, String checkout) {
  final args = item.bazelArgs;
  if (args == null) {
    throw ArgumentError('${item.name}: scripts run on Linux only');
  }
  final dir = item.folder == '.'
      ? checkout
      : '$checkout\\${item.folder.replaceAll('/', '\\')}';
  return 'cmd /v:on /c "cd /d $dir && '
      'bazel --output_base=C:/b/${folderHash(item.folder)} ${args.join(' ')} & '
      'echo $_exitMark!errorlevel!"';
}

/// The command that stops the Bazel server of [item]'s folder, and its
/// workers, on a VM whose checkout is at [checkout]: after a timeout, the
/// build goes on without the SSH session that started it.
///
/// It finds the server by its output base's pid file: `C:/b/<hash>` on
/// Windows ([windowsCommand]), and Bazel's default on Linux, named for the
/// workspace's path. A script that runs Bazel in other folders leaves those
/// servers running. Nothing to stop is not an error.
String stopCommand(E2eItem item, String checkout, {required bool windows}) {
  if (windows) {
    final pidFile = 'C:\\b\\${folderHash(item.folder)}\\server\\server.pid.txt';
    return 'cmd /c "if exist $pidFile '
        'for /f %p in ($pidFile) do taskkill /f /t /pid %p"';
  }
  final dir = item.folder == '.' ? checkout : '$checkout/${item.folder}';
  // The server leads its own process group; its persistent workers exit
  // when it does.
  final script =
      'ws=\$(cd "$dir" && pwd -P)\n'
      'base="\$HOME/.cache/bazel/_bazel_\$USER/'
      '\$(printf %s "\$ws" | md5sum | cut -c1-32)"\n'
      'pid=\$(cat "\$base/server/server.pid.txt" 2>/dev/null) || exit 0\n'
      'kill -9 -- "-\$pid" 2>/dev/null\n'
      'sleep 1\n'
      '! kill -0 "\$pid" 2>/dev/null\n';
  return "bash -c 'echo ${base64Word(script)} | base64 -d | bash'";
}

/// Eight hex digits of [folder]'s FNV-1a hash.
String folderHash(String folder) {
  var h = 0x811c9dc5;
  for (final unit in folder.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// [arg] as one bash word.
String shellQuote(String arg) => RegExp(r'^[\w@%+=:,./-]+$').hasMatch(arg)
    ? arg
    : "'${arg.replaceAll("'", r"'\''")}'";

/// The last [lines] lines of [s].
String tail(String s, {int lines = 60}) {
  final all = s.split('\n');
  return all.length <= lines ? s : all.sublist(all.length - lines).join('\n');
}

/// The checkout `bazel run` was run in.
String checkoutRoot() {
  final fromBazel = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromBazel != null && fromBazel.isNotEmpty) return fromBazel;
  final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (r.exitCode != 0) throw Exception('Not in a git checkout: ${r.stderr}');
  return r.stdout.toString().trim();
}

/// Packs the files of [root]'s HEAD commit into a `.tar` in [tmp], and
/// returns its path. Changes not committed are not in it; it warns of any.
///
/// `git archive` writes it, so no host `tar` is needed (Windows' crashes on a
/// name that is not ASCII), but from a scratch repository that borrows
/// [root]'s objects: there, `info/attributes` turns off what `.gitattributes`
/// and the host's configuration would do to an archive. Nothing marked
/// `export-ignore` (a repository's `e2e/`, `examples/`) is left out, and every
/// file is as committed: no `export-subst`, filter or line-ending conversion
/// (which Git for Windows turns on).
/// Not gzipped: the copy compresses in transit, and Git's tar on a Windows VM
/// finds no gzip to call.
String packageCommittedTree(String root, String tmp) {
  final dirty = Process.runSync('git', [
    '-C',
    root,
    'status',
    '--porcelain',
    '--untracked-files=no',
  ]);
  if (dirty.stdout.toString().trim().isNotEmpty) {
    stderr.writeln(
      'WARNING: changes not committed are NOT included; the VM runs HEAD. '
      'Commit first to test them.',
    );
  }
  String git(List<String> args) => _run('git', args).trim();
  final head = git(['-C', root, 'rev-parse', 'HEAD']);
  final objects = git([
    '-C',
    root,
    'rev-parse',
    '--path-format=absolute',
    '--git-path',
    'objects',
  ]);
  final scratch = '$tmp/archive.git';
  git(['init', '--quiet', '--bare', scratch]);
  File('$scratch/objects/info/alternates').writeAsStringSync('$objects\n');
  File('$scratch/info/attributes')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '* -export-ignore -export-subst -text -filter -ident '
      '-working-tree-encoding\n',
    );
  final tar = '$tmp/src.tar';
  stdout.writeln('Packaging HEAD -> $tar');
  git(['--git-dir=$scratch', 'archive', '--format=tar', '--output=$tar', head]);
  return tar;
}

Future<void> _transfer(E2eVm vm, String tar, String repo) async {
  stdout.writeln('Copying the tree to ${vm.name} ...');
  if (vm.windows) {
    await vm.copyTo(tar, 'C:/src_$repo.tar', compress: true);
    // Separate, simple commands: a compound `cmd /c "... & ..."` through
    // gcloud ssh can silently do nothing.
    await vm.exec('rmdir /s /q ${vm.checkout}'); // absent the first time
    await vm.run('mkdir ${vm.checkout}');
    // Git's GNU tar, not Windows' tar.exe, which cannot decode a UTF-8 path
    // from a pax header and so drops or misnames files with such names. GNU
    // tar reads `C:/...` as a remote host, hence the MSYS `/c/` form.
    await vm.run(
      '"C:\\Program Files\\Git\\usr\\bin\\tar.exe" '
      '-xf /c/src_$repo.tar -C /c/src/$repo',
    );
  } else {
    await vm.copyTo(tar, '~/src_$repo.tar', compress: true);
    // A repository, as CI's checkout is: scripts restore what they change
    // with `git checkout`.
    await vm.run(
      "bash -lc 'rm -rf ${vm.checkout} && mkdir -p ${vm.checkout} && "
      'tar xf ~/src_$repo.tar -C ${vm.checkout} && cd ${vm.checkout} && '
      'git init -q && git add -A && '
      "git -c user.name=e2e -c user.email=e2e@localhost commit -qm HEAD'",
    );
  }
}

/// Waits for the VM's startup script to finish installing the toolchain.
Future<void> _waitForToolchain(E2eVm vm) async {
  stdout.writeln('Checking the toolchain on ${vm.name} ...');
  if (vm.windows) {
    final reason = await waitForWindowsStartup(
      vm.name,
      budget: const Duration(minutes: 30),
    );
    if (reason != null) throw Exception(reason);
    return;
  }
  final deadline = DateTime.now().add(const Duration(minutes: 10));
  while (true) {
    final r = await ssh(
      vm.name,
      'cat /tmp/startup_complete 2>/dev/null',
      quiet: true,
    );
    final mark = r.stdout.toString();
    if (mark.contains('STARTUP_COMPLETE')) return;
    if (mark.contains('STARTUP_FAILED')) {
      throw Exception(
        '${vm.name}: the startup script failed. Its log: gcloud compute ssh '
        "${vm.name} --command 'sudo journalctl -u google-startup-scripts'",
      );
    }
    if (DateTime.now().isAfter(deadline)) {
      throw Exception('Timed out waiting for the toolchain on ${vm.name}');
    }
    stdout.writeln('  not ready yet; waiting ...');
    await Future<void>.delayed(const Duration(seconds: 20));
  }
}

String _usage(Map<String, String> options, String usage) => [
  'Usage: run_e2e <vm-name> [--windows] [--folders=a,b] [--keep-going] '
      '[--remote-cache=<url>]${options.keys.map((o) => ' [--$o=...]').join()}',
  if (usage.isNotEmpty) '\n$usage',
  '',
  '  --windows        the VM is Windows',
  '  --folders=a,b    run these folders only',
  '  --keep-going     run every item even after one fails',
  '  --remote-cache=  a Bazel remote cache the VMs share',
  for (final MapEntry(:key, :value) in options.entries) '  --$key=  $value',
].join('\n');

String _normalize(String dir) {
  var d = dir;
  while (d.startsWith('./')) {
    d = d.substring(2);
  }
  while (d.endsWith('/') && d.length > 1) {
    d = d.substring(0, d.length - 1);
  }
  return d.isEmpty ? '.' : d;
}

/// Runs [exe] and returns its stdout; throws, with its exit code and output,
/// when it fails.
String _run(String exe, List<String> args, {Map<String, String>? environment}) {
  final r = Process.runSync(exe, args, environment: environment);
  if (r.exitCode != 0) {
    throw Exception(
      '$exe ${args.join(' ')} failed (exit ${r.exitCode}):\n'
      '${r.stdout}${r.stderr}',
    );
  }
  return '${r.stdout}';
}

final class _Result {
  _Result(this.item, this.exitCode, this.pass, this.tail);
  final E2eItem item;
  final int exitCode;
  final bool pass;
  final String tail;
}
