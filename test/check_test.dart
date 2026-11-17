import 'package:rynsy_rules/src/banned.dart';
import 'package:rynsy_rules/src/comments.dart';
import 'package:rynsy_rules/src/options.dart';
import 'package:test/test.dart';

import 'helpers.dart';

List<int> commentLines(String source) =>
    fileCommentFindings('lib/a.dart', source).map((f) => f.line).toList();

void main() {
  group('RYD001', () {
    test('doc comments on declarations pass', () {
      expect(
        commentLines('''
/// The library.
library;

/// A class.
class A {
  /// A field.
  final int x = 1;

  /// A method.
  void m() {}
}

/// A function.
void f() {}
'''),
        isEmpty,
      );
    });

    test('plain, block, trailing and in-body doc comments fail', () {
      expect(
        commentLines('''
// plain
/* block */
/** javadoc */
void f() {
  /// dangling doc
  final x = 1; // trailing
}
'''),
        [1, 2, 3, 5, 6],
      );
    });

    test('TODO and ponytail allow two continuation lines', () {
      expect(
        commentLines('''
// TODO(#12) first
// second
// third
// fourth
void f() {
  // ponytail: global lock
  // per-account if needed
}
// TODO(#x) not an issue number
// TODO: no issue
'''),
        [4, 9, 10],
      );
    });

    test('a suppression needs a TODO on the line above', () {
      expect(
        commentLines('''
// ignore: unused_element
void _a() {}
// TODO(#3) remove once the API takes a stream
// ignore: unused_element
void _b() {}
// ignore_for_file: avoid_print
// coverage:ignore-line
'''),
        [1, 6, 7],
      );
    });

    test('comments inside strings are not comments', () {
      expect(commentLines("const s = '// not a comment';\n"), isEmpty);
    });
  });

  group('RYD002', () {
    test('the clock and sleep are banned in lib/ by any route', () async {
      final root = fixture({
        'lib/a.dart': '''
import 'dart:io' as io;

final a = DateTime.now();
final c = DateTime.now;
final d = DateTime.timestamp();
final e = Stopwatch();
void f() => io.sleep(Duration.zero);
final g = io.sleep;
final ok = DateTime(2020);
''',
        'lib/b.dart': '''
import 'dart:core' as core;

final b = core.DateTime.now();
final ok = core.DateTime(2020);
''',
        'lib/main.dart': 'final now = DateTime.now();\n',
        'test/a_test.dart': 'final now = DateTime.now();\n',
      });
      final findings = await bannedFindings(root);
      expect(findings.map((f) => '${f.path}:${f.line}'), [
        'lib/a.dart:3',
        'lib/a.dart:4',
        'lib/a.dart:5',
        'lib/a.dart:6',
        'lib/a.dart:7',
        'lib/a.dart:8',
        'lib/b.dart:3',
      ]);
    });
  });

  group('RYD003', () {
    test('the shared include alone passes', () {
      final root = fixture({
        'analysis_options.yaml': 'include: $sharedInclude\n',
      });
      expect(optionsFindings(root), isEmpty);
    });

    test('local rules, a missing file and nested configs fail', () {
      final local = fixture({
        'analysis_options.yaml':
            'include: $sharedInclude\n'
            'linter:\n  rules:\n    avoid_print: false\n',
        'lib/analysis_options.yaml': 'include: $sharedInclude\n',
        'packages/service_api/analysis_options.yaml': 'linter:\n',
      });
      expect(optionsFindings(local).map((f) => f.path), [
        'analysis_options.yaml',
        'lib/analysis_options.yaml',
      ]);
      expect(optionsFindings(fixture({'a.txt': ''})), hasLength(1));
    });
  });
}
