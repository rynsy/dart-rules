import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:rynsy_rules/src/finding.dart';

/// `library uri` -> `Class.member` (or a top-level name) that reads the wall
/// clock or blocks the isolate. Product code gets time from an injected clock.
const banned = {
  'dart:core': {'DateTime.now', 'DateTime.timestamp', 'Stopwatch.new'},
  'dart:io': {'sleep'},
};

const _exempt = {'lib/main.dart'};

List<String> bannedTargets(String root) => trackedFiles(
  root,
  ['lib/*.dart', 'lib/**/*.dart'],
).where((p) => !_exempt.contains(p) && !p.endsWith('.g.dart')).toSet().toList();

Future<List<Finding>> bannedFindings(String root) async {
  final targets = bannedTargets(root);
  if (targets.isEmpty) {
    return [];
  }
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
  }
  return findings;
}

String? bannedName(Element? element) {
  if (element == null) {
    return null;
  }
  final library = element.library?.uri.toString();
  final names = banned[library];
  if (names == null) {
    return null;
  }
  final String name;
  if (element is ConstructorElement) {
    final ctor = element.name ?? 'new';
    name = '${element.enclosingElement.name}.${ctor.isEmpty ? 'new' : ctor}';
  } else if (element is TopLevelFunctionElement) {
    name = element.name ?? '';
  } else {
    return null;
  }
  return names.contains(name) ? name : null;
}

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
