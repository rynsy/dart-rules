import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:rynsy_rules/src/banned.dart' show packageName;
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
/// called from `lib/`, and the paths of every `GoRoute` in `lib/`, each with
/// the `lib/` files where it appears.
class Surface {
  final operations = <String, Set<String>>{};
  final routes = <String, Set<String>>{};
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

/// One resolved view of `lib/` and `test/`.
class Resolved {
  Resolved(this.root, this.lib, this.tests)
    : _absolute = Directory(root).absolute.path {
    final all = [...lib, ...tests];
    _collection = all.isEmpty
        ? null
        : AnalysisContextCollection(
            includedPaths: [for (final p in all) '$_absolute/$p'],
          );
  }

  factory Resolved.of(String root) => Resolved(
    root,
    trackedFiles(root, ['lib/*.dart', 'lib/**/*.dart']),
    trackedFiles(root, ['test/*.dart', 'test/**/*.dart']),
  );

  final String root;
  final List<String> lib;
  final List<String> tests;
  final String _absolute;
  AnalysisContextCollection? _collection;

  Future<ResolvedUnitResult?> unit(String path) async {
    final collection = _collection;
    if (collection == null) {
      return null;
    }
    final file = '$_absolute/$path';
    final result = await collection
        .contextFor(file)
        .currentSession
        .getResolvedUnit(file);
    return result is ResolvedUnitResult ? result : null;
  }
}

Future<Surface> readSurface(
  Resolved resolved,
  Map<String, String> methods,
) async {
  final surface = Surface();
  for (final path in resolved.lib) {
    final result = await resolved.unit(path);
    if (result == null) {
      surface.problems.add(Finding(path, 1, 'features', 'could not resolve'));
      continue;
    }
    result.unit.accept(_SurfaceVisitor(path, result, methods, surface));
  }
  return surface;
}

bool _isGoRoute(InterfaceElement? element) =>
    element != null &&
    element.name == 'GoRoute' &&
    element.library.uri.toString().startsWith('package:go_router/');

bool _isGoRouteType(InterfaceElement? element) =>
    _isGoRoute(element) ||
    (element?.allSupertypes.any((t) => _isGoRoute(t.element)) ?? false);

class _SurfaceVisitor extends RecursiveAstVisitor<void> {
  _SurfaceVisitor(this.path, this.result, this.methods, this.surface);

  final String path;
  final ResolvedUnitResult result;
  final Map<String, String> methods;
  final Surface surface;

  int _line(AstNode node) =>
      result.lineInfo.getLocation(node.offset).lineNumber;

  void _problem(AstNode node, String message) =>
      surface.problems.add(Finding(path, _line(node), 'features', message));

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.realTarget?.staticType is DynamicType) {
      _problem(node, 'a dynamic call hides which operation runs');
    }
    super.visitMethodInvocation(node);
  }

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
        surface.operations.putIfAbsent(id, () => {}).add(path);
      }
    }
    super.visitSimpleIdentifier(node);
  }

  void _route(AstNode node, ArgumentList arguments, {required bool required}) {
    final value = arguments.arguments
        .whereType<NamedArgument>()
        .where((a) => a.name.lexeme == 'path')
        .map((a) => a.argumentExpression)
        .firstOrNull;
    if (value is SimpleStringLiteral) {
      surface.routes.putIfAbsent(value.value, () => {}).add(path);
    } else if (value != null || required) {
      _problem(node, 'a GoRoute path must be a string literal');
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.staticType;
    final element = type is InterfaceType ? type.element : null;
    if (_isGoRouteType(element)) {
      _route(node, node.argumentList, required: _isGoRoute(element));
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    if (_isGoRoute(node.element?.enclosingElement)) {
      _route(node, node.argumentList, required: false);
    }
    super.visitSuperConstructorInvocation(node);
  }
}

const _assertions = {'expect', 'expectLater', 'fail'};
const _testLibraries = [
  'package:matcher/',
  'package:test_api/',
  'package:test/',
  'package:flutter_test/',
];

bool _fromTestLibrary(Element? element) {
  final uri = element?.library?.uri.toString() ?? '';
  return _testLibraries.any(uri.startsWith);
}

bool _isAssertion(Element? element) =>
    element is TopLevelFunctionElement &&
    _assertions.contains(element.name) &&
    _fromTestLibrary(element);

String? _key(Element? element) => element is TopLevelFunctionElement
    ? '${element.library.uri}#${element.name}'
    : null;

/// Top-level functions in the test tree that call a real assertion, directly
/// or through another such function. Keyed by library and name, so a local
/// `expect` or a same-named helper elsewhere does not count.
Future<Set<String>> assertingHelpers(Resolved resolved) async {
  final calls = <String, Set<String>>{};
  final asserting = <String>{};
  for (final path in resolved.tests) {
    final result = await resolved.unit(path);
    if (result == null) {
      continue;
    }
    for (final fn
        in result.unit.declarations.whereType<FunctionDeclaration>()) {
      final key = _key(fn.declaredFragment?.element);
      if (key == null) {
        continue;
      }
      final collector = _Calls();
      fn.accept(collector);
      if (collector.elements.any(_isAssertion)) {
        asserting.add(key);
      }
      calls
          .putIfAbsent(key, () => {})
          .addAll(collector.elements.map(_key).nonNulls);
    }
  }
  var grew = true;
  while (grew) {
    grew = false;
    for (final MapEntry(:key, :value) in calls.entries) {
      if (!asserting.contains(key) && value.any(asserting.contains)) {
        asserting.add(key);
        grew = true;
      }
    }
  }
  return asserting;
}

/// Static part: the proof is a `test`/`testWidgets` call with literal names
/// (groups included), is not skipped, and can fail through a real assertion.
Future<String?> staticProblem(
  Resolved resolved,
  Proof proof,
  Set<String> helpers,
) async {
  if (!File('${resolved.root}/${proof.file}').existsSync()) {
    return 'no such file';
  }
  final result = await resolved.unit(proof.file);
  if (result == null) {
    return 'could not resolve (is it tracked by git?)';
  }
  final finder = _TestFinder(proof.name);
  result.unit.accept(finder);
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
  final collector = _Calls();
  body.accept(collector);
  if (collector.elements.any(
    (e) => e?.name == 'markTestSkipped' && _fromTestLibrary(e),
  )) {
    return 'the test can skip itself';
  }
  if (!collector.elements.any(
    (e) => _isAssertion(e) || helpers.contains(_key(e)),
  )) {
    return 'the test cannot fail: no expect, expectLater or fail from the '
        'test packages, and no helper in test/ that calls one';
  }
  return null;
}

/// Every library [path] imports or exports, transitively.
Future<Set<String>> reachable(Resolved resolved, String path) async {
  final result = await resolved.unit(path);
  final start = result?.libraryElement;
  if (start == null) {
    return {};
  }
  final seen = <String>{};
  final queue = <LibraryElement>[start];
  while (queue.isNotEmpty) {
    final library = queue.removeLast();
    if (!seen.add(library.uri.toString())) {
      continue;
    }
    for (final fragment in library.fragments) {
      queue.addAll(fragment.importedLibraries);
    }
    queue.addAll(library.exportedLibraries);
  }
  return seen;
}

class _Calls extends RecursiveAstVisitor<void> {
  final elements = <Element?>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    elements.add(node.methodName.element);
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
  final resolved = Resolved.of(root);
  final surface = await readSurface(resolved, methods);
  problems.addAll(surface.problems.map((f) => f.toString()));

  final listedOps = {for (final f in features) ...f.operations};
  final listedRoutes = {for (final f in features) ...f.routes};
  final calledOps = surface.operations.keys.toSet();
  final declaredRoutes = surface.routes.keys.toSet();
  for (final op in calledOps.difference(listedOps)) {
    problems.add('operation $op is called from lib/ but belongs to no feature');
  }
  for (final route in declaredRoutes.difference(listedRoutes)) {
    problems.add('route $route is in lib/ but belongs to no feature');
  }
  for (final op in listedOps.difference(calledOps)) {
    problems.add('operation $op is listed but lib/ never calls it');
  }
  for (final route in listedRoutes.difference(declaredRoutes)) {
    problems.add('route $route is listed but no GoRoute has this path');
  }

  final package = packageName(root);
  String uriOf(String libPath) => 'package:$package/${libPath.substring(4)}';
  final names = <String>{};
  final proofs = <Proof>[];
  final helpers = await assertingHelpers(resolved);
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
    final reached = <String>{};
    var allSound = true;
    for (final text in feature.provenBy) {
      final proof = Proof.parse(text);
      if (proof == null) {
        problems.add(
          'feature "${feature.name}": "$text" is not '
          'test/<file>_test.dart:<full test name>',
        );
        allSound = false;
        continue;
      }
      final problem = await staticProblem(resolved, proof, helpers);
      if (problem != null) {
        problems.add('feature "${feature.name}": $proof: $problem');
        allSound = false;
        continue;
      }
      reached.addAll(await reachable(resolved, proof.file));
      proofs.add(proof);
    }
    final sites = {
      for (final op in feature.operations)
        'operation $op': surface.operations[op] ?? const <String>{},
      for (final route in feature.routes)
        'route $route': surface.routes[route] ?? const <String>{},
    };
    for (final MapEntry(:key, :value) in sites.entries) {
      if (allSound &&
          value.isNotEmpty &&
          !value.any((f) => reached.contains(uriOf(f)))) {
        problems.add(
          'feature "${feature.name}": no proof imports ${value.join(' or ')}, '
          'where $key is',
        );
      }
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
