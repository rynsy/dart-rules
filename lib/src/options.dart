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
        !path.startsWith('packages/service_api/') &&
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
  findings.addAll(pubspecFindings(root));
  return findings;
}

const rulesUrl = 'https://github.com/rynsy/dart-rules.git';

/// The pubspec cannot swap the checker or the analyzer config: no
/// `dependency_overrides`, `rynsy_rules` only from [rulesUrl], and no path
/// dependency other than the generated client.
List<Finding> pubspecFindings(String root) {
  final file = File('$root/pubspec.yaml');
  if (!file.existsSync() || _isThisPackage(root)) {
    return [];
  }
  final doc = loadYaml(file.readAsStringSync());
  if (doc is! Map) {
    return [Finding('pubspec.yaml', 1, 'RYD003', 'not a YAML map')];
  }
  final findings = <Finding>[];
  void add(String message) =>
      findings.add(Finding('pubspec.yaml', 1, 'RYD003', message));
  if (doc.containsKey('dependency_overrides')) {
    add('dependency_overrides can replace the checker or its config');
  }
  if (File('$root/pubspec_overrides.yaml').existsSync()) {
    add('pubspec_overrides.yaml can replace the checker or its config');
  }
  Object? rules;
  for (final section in ['dependencies', 'dev_dependencies']) {
    final deps = doc[section];
    if (deps is! Map) {
      continue;
    }
    for (final MapEntry(:key, :value) in deps.entries) {
      if (key == 'rynsy_rules') {
        rules = value;
      }
      if (value is Map &&
          value.containsKey('path') &&
          value['path'] != 'packages/service_api') {
        add('$key is a path dependency; only packages/service_api may be');
      }
    }
  }
  final git = rules is Map ? rules['git'] : null;
  if (git is! Map || git['url'] != rulesUrl || git['path'] != null) {
    add('rynsy_rules must be a git dependency on $rulesUrl pinned by ref');
  }
  return findings;
}

bool _isThisPackage(String root) {
  final pubspec = File('$root/pubspec.yaml');
  return pubspec.existsSync() &&
      (loadYaml(pubspec.readAsStringSync()) as Map)['name'] == 'rynsy_rules';
}
