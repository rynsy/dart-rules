import 'dart:io';

/// A throwaway git repo holding [files], all tracked.
String fixture(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('rynsy_rules_').path;
  for (final MapEntry(:key, :value) in files.entries) {
    File('$root/$key')
      ..createSync(recursive: true)
      ..writeAsStringSync(value);
  }
  for (final args in [
    ['init', '-q'],
    ['add', '-A'],
  ]) {
    final result = Process.runSync('git', args, workingDirectory: root);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')}: ${result.stderr}');
    }
  }
  return root;
}

void pubGet(String root) {
  final result = Process.runSync('dart', [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: root);
  if (result.exitCode != 0) {
    throw StateError('pub get: ${result.stdout}${result.stderr}');
  }
}
