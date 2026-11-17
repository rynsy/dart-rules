import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:rynsy_rules/src/finding.dart';
import 'package:yaml/yaml.dart';

/// `library uri` -> `Class.member` (or a top-level name) that reads the wall
/// clock or blocks the isolate. Product code gets time from an injected clock.
/// A banned constructor is banned for every subclass too.
const banned = {
  'dart:core': {'DateTime.now', 'DateTime.timestamp', 'Stopwatch.new'},
  'dart:io': {'sleep'},
  'dart:developer': {'Timeline.now'},
};

const _exempt = {'lib/main.dart'};

List<String> bannedTargets(String root) => trackedFiles(root, [
  'lib/*.dart',
  'lib/**/*.dart',
]).where((p) => !_exempt.contains(p)).toSet().toList();

String? packageName(String root) {
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) {
    return null;
  }
  final doc = loadYaml(pubspec.readAsStringSync());
  return doc is Map ? doc['name'] as String? : null;
}

Future<List<Finding>> bannedFindings(String root) async {
  final targets = bannedTargets(root);
  if (targets.isEmpty) {
    return [];
  }
  final mainUri = 'package:${packageName(root)}/main.dart';
  final absolute = Directory(root).absolute.path;
  final collection = AnalysisContextCollection(
    includedPaths: [for (final p in targets) '$absolute/$p'],
  );
  final findings = <Finding>[];
  for (final path in targets) {
    final file = '$absolute/$path';
    final result = await collection
        .contextFor(file)
        .currentSession
        .getResolvedUnit(file);
    if (result is! ResolvedUnitResult) {
      findings.add(Finding(path, 1, 'RYD002', 'could not resolve this file'));
      continue;
    }
    final visitor = _BannedUses(path, result.lineInfo);
    result.unit.accept(visitor);
    findings.addAll(visitor.findings);
    final here = Uri.parse('package:${packageName(root)}/${path.substring(4)}');
    for (final directive in result.unit.directives) {
      final text = directive is NamespaceDirective
          ? directive.uri.stringValue
          : null;
      final imported = text == null ? null : here.resolve(text).toString();
      if (imported == mainUri) {
        findings.add(
          Finding(
            path,
            result.lineInfo.getLocation(directive.offset).lineNumber,
            'RYD002',
            'lib/main.dart is the composition root and may read the clock; '
                'nothing in lib/ imports it',
          ),
        );
      }
    }
  }
  return findings;
}

String? bannedName(Element? element) {
  if (element == null) {
    return null;
  }
  if (element is ConstructorElement) {
    final owner = element.enclosingElement;
    final ctor = element.name ?? 'new';
    final own = '${owner.name}.${ctor.isEmpty ? 'new' : ctor}';
    if (_isBanned(owner.library.uri.toString(), own)) {
      return own;
    }
    for (final type in owner.allSupertypes) {
      final name = '${type.element.name}.new';
      if (_isBanned(type.element.library.uri.toString(), name)) {
        return '$name (through ${owner.name})';
      }
    }
    return null;
  }
  final library = element.library?.uri.toString() ?? '';
  if (element is TopLevelFunctionElement) {
    final name = element.name ?? '';
    return _isBanned(library, name) ? name : null;
  }
  if (element is ExecutableElement) {
    final owner = element.enclosingElement;
    if (owner is InterfaceElement) {
      final name = '${owner.name}.${element.name}';
      return _isBanned(library, name) ? name : null;
    }
  }
  return null;
}

bool _isBanned(String library, String name) =>
    banned[library]?.contains(name) ?? false;

class _BannedUses extends RecursiveAstVisitor<void> {
  _BannedUses(this.path, this.lines);

  final String path;
  final LineInfo lines;
  final findings = <Finding>[];

  void _check(AstNode node, Element? element) {
    final name = bannedName(element);
    if (name == null) {
      return;
    }
    final line = lines.getLocation(node.offset).lineNumber;
    findings.add(
      Finding(
        path,
        line,
        'RYD002',
        '$name reads the clock or blocks: inject a clock from lib/main.dart, '
            'or wait on the event',
      ),
    );
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _check(node, node.element);
    super.visitConstructorName(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _check(node, node.element);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.parent is! ConstructorName) {
      final element = node.element;
      if (element is! ConstructorElement) {
        _check(node, element);
      }
    }
    super.visitSimpleIdentifier(node);
  }
}
