import 'dart:io';

import 'package:rynsy_rules/src/banned.dart';
import 'package:rynsy_rules/src/comments.dart';
import 'package:rynsy_rules/src/features.dart';
import 'package:rynsy_rules/src/options.dart';

const usage = '''
usage: dart run rynsy_rules <command>
  check      RYD001 comments, RYD002 clock and sleep, RYD003 analyzer config
  features   [--openapi openapi/openapi.json] [--features features.json]''';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  switch (args) {
    case ['check']:
      final findings = [
        ...optionsFindings(root),
        ...commentFindings(root),
        ...await bannedFindings(root),
      ];
      stdout.writeAll(findings.map((f) => '$f\n'));
      exitCode = findings.isEmpty ? 0 : 1;
    case ['features', ...final rest]:
      final options = _options(rest);
      if (options == null) {
        stderr.writeln(usage);
        exitCode = 2;
        return;
      }
      final problems = await featureProblems(
        root,
        spec: options['--openapi'] ?? 'openapi/openapi.json',
        featuresPath: options['--features'] ?? 'features.json',
      );
      stdout.writeAll(problems.map((p) => '$p\n'));
      exitCode = problems.isEmpty ? 0 : 1;
    default:
      stderr.writeln(usage);
      exitCode = 2;
  }
}

Map<String, String>? _options(List<String> rest) {
  if (rest.length.isOdd) {
    return null;
  }
  final options = <String, String>{};
  for (var i = 0; i < rest.length; i += 2) {
    if (rest[i] != '--openapi' && rest[i] != '--features') {
      return null;
    }
    options[rest[i]] = rest[i + 1];
  }
  return options;
}
