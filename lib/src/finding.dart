import 'dart:io';

class Finding {
  Finding(this.path, this.line, this.rule, this.message);

  final String path;
  final int line;
  final String rule;
  final String message;

  @override
  String toString() => '$path:$line: $rule $message';
}

List<String> trackedFiles(String root, List<String> patterns) {
  final result = Process.runSync('git', [
    'ls-files',
    '-z',
    '--',
    ...patterns,
  ], workingDirectory: root);
  if (result.exitCode != 0) {
    throw StateError('git ls-files failed: ${result.stderr}');
  }
  return (result.stdout as String)
      .split('\x00')
      .where((p) => p.isNotEmpty && File('$root/$p').existsSync())
      .toList();
}
