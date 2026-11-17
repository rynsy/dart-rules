import 'dart:io';

import 'package:rynsy_rules/src/finding.dart';
import 'package:yaml/yaml.dart';

const sharedInclude = 'package:rynsy_rules/analysis_options.yaml';

/// The analyzer config is the shared one, unchanged: the root
/// `analysis_options.yaml` holds the include and nothing else, and no other
/// tracked options file (outside the generated `packages/`) overrides it.
List<Finding> optionsFindings(String root) {
  final findings = <Finding>[];
  final file = File('$root/analysis_options.yaml');
  if (!file.existsSync()) {
    return [
      Finding(
        'analysis_options.yaml',
        1,
        'RYD003',
        'missing: it must be exactly `include: $sharedInclude`',
      ),
    ];
  }
  Object? doc;
  try {
    doc = loadYaml(file.readAsStringSync());
  } on YamlException catch (e) {
    doc = e;
  }
  if (doc is! Map || doc.length != 1 || doc['include'] != sharedInclude) {
    findings.add(
      Finding(
        'analysis_options.yaml',
        1,
        'RYD003',
        'must be exactly `include: $sharedInclude` (`flutter pub add` '
            'rewrites it: restore it from git); a rule every app needs '
            'belongs in dart-rules, a one-off is `// ignore:` under a '
            '`// TODO(#<issue>)`',
      ),
    );
  }
  for (final path in trackedFiles(root, [
    'analysis_options.yaml',
    '**/analysis_options.yaml',
  ])) {
    if (path != 'analysis_options.yaml' &&
        !path.startsWith('packages/') &&
        !(path == 'lib/analysis_options.yaml' && _isThisPackage(root))) {
      findings.add(
        Finding(
          path,
          1,
          'RYD003',
          'a nested analyzer config overrides the shared one',
        ),
      );
    }
  }
  return findings;
}

bool _isThisPackage(String root) {
  final pubspec = File('$root/pubspec.yaml');
  return pubspec.existsSync() &&
      (loadYaml(pubspec.readAsStringSync()) as Map)['name'] == 'rynsy_rules';
}
