import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:rynsy_rules/src/finding.dart';

final _todo = RegExp(r'^// TODO\(#\d+\)');
final _ponytail = RegExp(r'^// ponytail: \S');
final _suppression = RegExp(
  r'^//\s*(ignore\s*:|ignore_for_file\s*:|coverage:ignore)',
);

const continuationLines = 2;

/// Files the comment rule reads: tracked Dart files outside the generated
/// client (`packages/`) and generated `*.g.dart` parts.
List<String> commentTargets(String root) => trackedFiles(root, [
  '*.dart',
]).where((p) => !p.startsWith('packages/') && !p.endsWith('.g.dart')).toList();

List<Finding> commentFindings(String root) => [
  for (final path in commentTargets(root))
    ...fileCommentFindings(path, File('$root/$path').readAsStringSync()),
];

List<Finding> fileCommentFindings(String path, String source) {
  final unit = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  ).unit;
  final docs = _DocTokens();
  unit.accept(docs);
  final lines = unit.lineInfo;
  final findings = <Finding>[];
  final allowedLines = <int>{};
  final todoLines = <int>{};

  for (final comment in _comments(unit)) {
    final text = comment.lexeme;
    final line = lines.getLocation(comment.offset).lineNumber;
    if (docs.offsets.contains(comment.offset)) {
      continue;
    }
    if (_todo.hasMatch(text) || _ponytail.hasMatch(text)) {
      if (_todo.hasMatch(text)) {
        todoLines.add(line);
      }
      allowedLines.add(line);
      _continuations(comment, lines, line, allowedLines);
      continue;
    }
    if (allowedLines.contains(line)) {
      continue;
    }
    if (_suppression.hasMatch(text)) {
      if (!todoLines.contains(line - 1)) {
        findings.add(
          Finding(
            path,
            line,
            'RYD001',
            'a suppression needs a `// TODO(#<issue>)` on the line above it',
          ),
        );
      }
      continue;
    }
    findings.add(
      Finding(
        path,
        line,
        'RYD001',
        'comment: only doc comments, `// TODO(#<issue>)` and '
            '`// ponytail: <ceiling>` are allowed; say it with a name, a '
            'type or a test',
      ),
    );
  }
  return findings;
}

void _continuations(Token comment, LineInfo lines, int line, Set<int> allowed) {
  var next = comment.next;
  var expected = line + 1;
  while (next != null && expected <= line + continuationLines) {
    final at = lines.getLocation(next.offset).lineNumber;
    if (at != expected ||
        !next.lexeme.startsWith('//') ||
        next.lexeme.startsWith('///')) {
      return;
    }
    allowed.add(at);
    expected++;
    next = next.next;
  }
}

Iterable<Token> _comments(CompilationUnit unit) sync* {
  Token? token = unit.beginToken;
  while (token != null) {
    Token? comment = token.precedingComments;
    while (comment != null) {
      yield comment;
      comment = comment.next;
    }
    if (token.type == TokenType.EOF) {
      return;
    }
    token = token.next;
  }
}

class _DocTokens extends GeneralizingAstVisitor<void> {
  final offsets = <int>{};

  @override
  void visitComment(Comment node) {
    for (final token in node.tokens) {
      if (token.lexeme.startsWith('///')) {
        offsets.add(token.offset);
      }
    }
  }
}
