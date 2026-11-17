import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:rynsy_rules/src/finding.dart';

const clientPackage = 'package:service_api/';

class Feature {
  Feature(this.name, this.operations, this.routes, this.provenBy);

  factory Feature.fromJson(Map<String, Object?> json) => Feature(
    json['name']! as String,
    [...(json['operations'] as List<Object?>? ?? const []).cast<String>()],
    [...(json['routes'] as List<Object?>? ?? const []).cast<String>()],
    [...(json['provenBy'] as List<Object?>? ?? const []).cast<String>()],
  );

  final String name;
  final List<String> operations;
  final List<String> routes;
  final List<String> provenBy;
}

class Proof {
  Proof(this.file, this.name);

  final String file;
  final String name;

  static Proof? parse(String text) {
    final at = text.indexOf('.dart:');
    if (at < 0) {
      return null;
    }
    final file = text.substring(0, at + 5);
    final name = text.substring(at + 6);
    if (!file.startsWith('test/') ||
        !file.endsWith('_test.dart') ||
        name.isEmpty) {
      return null;
    }
    return Proof(file, name);
  }

  @override
  String toString() => '$file:$name';
}

/// What the app does, read from the code: operations of the generated client
/// called from `lib/`, and the paths of every `GoRoute` in `lib/`.
class Surface {
  final operations = <String>{};
  final routes = <String>{};
  final problems = <Finding>[];
}

Map<String, String> operationIds(String specPath) {
  final spec =
      jsonDecode(File(specPath).readAsStringSync()) as Map<String, Object?>;
  final ids = <String, String>{};
  final paths = spec['paths'] as Map<String, Object?>? ?? const {};
  for (final item in paths.values) {
    for (final op in (item! as Map<String, Object?>).values) {
      if (op is Map && op['operationId'] is String) {
        final id = op['operationId'] as String;
        ids[_lowerCamel(id)] = id;
      }
    }
  }
  return ids;
}

String _lowerCamel(String id) {
  final parts = id.split(RegExp('[^A-Za-z0-9]+')).where((p) => p.isNotEmpty);
  final buffer = StringBuffer();
  for (final (i, p) in parts.indexed) {
    buffer.write(
      i == 0
          ? p[0].toLowerCase() + p.substring(1)
          : p[0].toUpperCase() + p.substring(1),
    );
  }
  return buffer.toString();
}

Future<Surface> readSurface(String root, Map<String, String> methods) async {
  final surface = Surface();
  final targets = trackedFiles(root, [
    'lib/*.dart',
    'lib/**/*.dart',
  ]).where((p) => !p.endsWith('.g.dart')).toList();
  if (targets.isEmpty) {
    return surface;
  }
  final absolute = Directory(root).absolute.path;
  final collection = AnalysisContextCollection(
    includedPaths: [for (final p in targets) '$absolute/$p'],
  );
  for (final path in targets) {
    final file = '$absolute/$path';
    final result = await collection
        .contextFor(file)
        .currentSession
        .getResolvedUnit(file);
    if (result is! ResolvedUnitResult) {
      surface.problems.add(Finding(path, 1, 'features', 'could not resolve'));
      continue;
    }
    result.unit.accept(_SurfaceVisitor(path, result, methods, surface));
  }
  return surface;
}

class _SurfaceVisitor extends RecursiveAstVisitor<void> {
  _SurfaceVisitor(this.path, this.result, this.methods, this.surface);

  final String path;
  final ResolvedUnitResult result;
  final Map<String, String> methods;
  final Surface surface;

  int _line(AstNode node) =>
      result.lineInfo.getLocation(node.offset).lineNumber;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    final library = element?.library?.uri.toString() ?? '';
    final name = element?.name;
    if (library.startsWith(clientPackage) && name != null) {
      final base = name.endsWith('WithHttpInfo')
          ? name.substring(0, name.length - 'WithHttpInfo'.length)
          : name;
      final id = methods[base];
      if (id != null &&
          element?.enclosingElement?.name?.endsWith('Api') == true) {
        surface.operations.add(id);
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.element;
    if (type?.name == 'GoRoute' &&
        (type?.library?.uri.toString() ?? '').startsWith(
          'package:go_router/',
        )) {
      final path = node.argumentList.arguments
          .whereType<NamedArgument>()
          .where((a) => a.name.lexeme == 'path')
          .map((a) => a.argumentExpression)
          .firstOrNull;
      if (path is SimpleStringLiteral) {
        surface.routes.add(path.value);
      } else {
        surface.problems.add(
          Finding(
            this.path,
            _line(node),
            'features',
            'a GoRoute path must be a string literal',
          ),
        );
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

/// Static part: the proof is a `test`/`testWidgets` call with literal names
/// (groups included), is not skipped, and can fail.
String? staticProblem(String root, Proof proof, Set<String> assertingHelpers) {
  final file = File('$root/${proof.file}');
  if (!file.existsSync()) {
    return 'no such file';
  }
  final unit = parseString(
    content: file.readAsStringSync(),
    path: proof.file,
    throwIfDiagnostics: false,
  ).unit;
  final finder = _TestFinder(proof.name);
  unit.accept(finder);
  final found = finder.found;
  if (found == null) {
    return 'no test with exactly this name '
        '(groups and test names must be string literals)';
  }
  if (finder.skipped) {
    return 'the test or one of its groups is skipped';
  }
  final body = found.argumentList.arguments.length > 1
      ? found.argumentList.arguments[1]
      : null;
  if (body == null) {
    return 'the test has no body';
  }
  final calls = _Calls();
  body.accept(calls);
  if (calls.names.contains('markTestSkipped')) {
    return 'the test can skip itself';
  }
  if (!calls.names.any(
    (n) => _assertions.contains(n) || assertingHelpers.contains(n),
  )) {
    return 'the test cannot fail: '
        'no expect, expectLater, fail or asserting helper';
  }
  return null;
}

const _assertions = {'expect', 'expectLater', 'fail'};

/// Top-level functions in the test tree that call an assertion, directly or
/// through another such function.
Set<String> assertingHelpers(String root) {
  final callsByFunction = <String, Set<String>>{};
  for (final path in trackedFiles(root, ['test/*.dart', 'test/**/*.dart'])) {
    final unit = parseString(
      content: File('$root/$path').readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    ).unit;
    for (final fn in unit.declarations.whereType<FunctionDeclaration>()) {
      final calls = _Calls();
      fn.accept(calls);
      callsByFunction.putIfAbsent(fn.name.lexeme, () => {}).addAll(calls.names);
    }
  }
  final asserting = <String>{};
  var grew = true;
  while (grew) {
    grew = false;
    for (final MapEntry(:key, :value) in callsByFunction.entries) {
      if (!asserting.contains(key) &&
          value.any((n) => _assertions.contains(n) || asserting.contains(n))) {
        asserting.add(key);
        grew = true;
      }
    }
  }
  return asserting;
}

class _Calls extends RecursiveAstVisitor<void> {
  final names = <String>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    names.add(node.methodName.name);
    super.visitMethodInvocation(node);
  }
}

class _TestFinder extends RecursiveAstVisitor<void> {
  _TestFinder(this.wanted);

  final String wanted;
  final _groups = <String>[];
  final _skippedGroups = <bool>[];
  MethodInvocation? found;
  bool skipped = false;

  static bool _hasSkip(MethodInvocation node) =>
      node.argumentList.arguments.whereType<NamedArgument>().any(
        (a) =>
            a.name.lexeme == 'skip' &&
            a.argumentExpression is! NullLiteral &&
            !(a.argumentExpression is BooleanLiteral &&
                !(a.argumentExpression as BooleanLiteral).value),
      );

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final args = node.argumentList.arguments;
    final first = args.isEmpty ? null : args.first;
    final literal = first is SimpleStringLiteral ? first.value : null;
    if (name == 'group' && literal != null) {
      _groups.add(literal);
      _skippedGroups.add(_hasSkip(node));
      super.visitMethodInvocation(node);
      _groups.removeLast();
      _skippedGroups.removeLast();
      return;
    }
    if ((name == 'test' || name == 'testWidgets') && literal != null) {
      final full = [..._groups, literal].join(' ');
      if (full == wanted) {
        found = node;
        skipped = _hasSkip(node) || _skippedGroups.contains(true);
      }
    }
    super.visitMethodInvocation(node);
  }
}

/// Runs every proof file once with the JSON reporter. A proof passes when a
/// test with exactly its full name finished `success`, not skipped, and
/// nothing else in its file failed or errored.
Map<String, String> runFailures(
  String root,
  List<Proof> proofs, {
  bool flutter = true,
}) {
  final files = {for (final p in proofs) p.file}.toList()..sort();
  if (files.isEmpty) {
    return {};
  }
  final command = flutter ? 'flutter' : 'dart';
  final result = Process.runSync(command, [
    'test',
    '--reporter',
    'json',
    ...files,
  ], workingDirectory: root);
  final suites = <int, String>{};
  final tests = <int, (int, String)>{};
  final passed = <String>{};
  final badFiles = <String>{};
  for (final line in (result.stdout as String).split('\n')) {
    if (!line.startsWith('{')) {
      continue;
    }
    final Map<String, Object?> event;
    try {
      event = jsonDecode(line) as Map<String, Object?>;
    } on FormatException {
      continue;
    }
    switch (event['type']) {
      case 'suite':
        final suite = event['suite']! as Map<String, Object?>;
        suites[suite['id']! as int] = _relative(
          root,
          suite['path'] as String? ?? '',
        );
      case 'testStart':
        final test = event['test']! as Map<String, Object?>;
        tests[test['id']! as int] = (
          test['suiteID']! as int,
          test['name']! as String,
        );
      case 'error':
        final test = tests[event['testID']];
        if (test != null) {
          badFiles.add(suites[test.$1] ?? '');
        }
      case 'testDone':
        final test = tests[event['testID']];
        if (test == null) {
          continue;
        }
        final file = suites[test.$1] ?? '';
        if (event['result'] != 'success') {
          badFiles.add(file);
        } else if (event['skipped'] != true && event['hidden'] != true) {
          passed.add('$file:${test.$2}');
        }
    }
  }
  final failures = <String, String>{};
  for (final proof in proofs) {
    final key = proof.toString();
    if (badFiles.contains(proof.file)) {
      failures[key] = 'a test in ${proof.file} failed or errored';
    } else if (!passed.contains(key)) {
      failures[key] = result.exitCode == 0
          ? 'did not run and pass (skipped, or no test with this exact name)'
          : '`$command test` exited ${result.exitCode} '
                'and this proof did not pass';
    }
  }
  return failures;
}

String _relative(String root, String path) {
  final base = '${Directory(root).absolute.path}/';
  return path.startsWith(base) ? path.substring(base.length) : path;
}

Future<List<String>> featureProblems(
  String root, {
  String spec = 'openapi/openapi.json',
  String featuresPath = 'features.json',
  bool run = true,
}) async {
  final problems = <String>[];
  final featuresFile = File('$root/$featuresPath');
  if (!featuresFile.existsSync()) {
    return ['$featuresPath: missing'];
  }
  final features = [
    for (final f
        in jsonDecode(featuresFile.readAsStringSync()) as List<Object?>)
      Feature.fromJson(f! as Map<String, Object?>),
  ];
  final methods = File('$root/$spec').existsSync()
      ? operationIds('$root/$spec')
      : <String, String>{};
  final surface = await readSurface(root, methods);
  problems.addAll(surface.problems.map((f) => f.toString()));

  final listedOps = {for (final f in features) ...f.operations};
  final listedRoutes = {for (final f in features) ...f.routes};
  for (final op in surface.operations.difference(listedOps)) {
    problems.add('operation $op is called from lib/ but belongs to no feature');
  }
  for (final route in surface.routes.difference(listedRoutes)) {
    problems.add('route $route is in lib/ but belongs to no feature');
  }
  for (final op in listedOps.difference(surface.operations)) {
    problems.add('operation $op is listed but lib/ never calls it');
  }
  for (final route in listedRoutes.difference(surface.routes)) {
    problems.add('route $route is listed but no GoRoute has this path');
  }

  final names = <String>{};
  final proofs = <Proof>[];
  final helpers = assertingHelpers(root);
  for (final feature in features) {
    if (!names.add(feature.name)) {
      problems.add('feature "${feature.name}" is listed twice');
    }
    if (feature.operations.isEmpty && feature.routes.isEmpty) {
      problems.add('feature "${feature.name}" names no operation or route');
    }
    if (feature.provenBy.isEmpty) {
      problems.add('feature "${feature.name}" names no proving test');
    }
    for (final text in feature.provenBy) {
      final proof = Proof.parse(text);
      if (proof == null) {
        problems.add(
          'feature "${feature.name}": "$text" is not test/<file>_test.dart:<full test name>',
        );
        continue;
      }
      final problem = staticProblem(root, proof, helpers);
      if (problem != null) {
        problems.add('feature "${feature.name}": $proof: $problem');
        continue;
      }
      proofs.add(proof);
    }
  }
  if (run && problems.isEmpty) {
    final pubspec = File('$root/pubspec.yaml');
    final flutter =
        pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('sdk: flutter');
    for (final MapEntry(:key, :value) in runFailures(
      root,
      proofs,
      flutter: flutter,
    ).entries) {
      problems.add('$key: $value');
    }
  }
  return problems;
}
