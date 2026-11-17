import 'dart:convert';

import 'package:rynsy_rules/src/features.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const spec = {
  'paths': {
    '/items': {
      'get': {'operationId': 'listItems'},
      'post': {'operationId': 'create-item'},
    },
    '/healthz': {
      'get': {'operationId': 'healthz'},
    },
  },
};

const app = {
  'pubspec.yaml': '''
name: app
environment:
  sdk: ^3.11.0
dependencies:
  service_api:
    path: packages/service_api
  go_router:
    path: packages/go_router
dev_dependencies:
  test: any
''',
  'packages/service_api/pubspec.yaml':
      'name: service_api\nenvironment:\n  sdk: ^3.11.0\n',
  'packages/service_api/lib/api.dart': '''
class DefaultApi {
  Future<int> listItems() async => 1;
  Future<int> createItemWithHttpInfo() async => 1;
  Future<int> healthz() async => 1;
}
''',
  'packages/go_router/pubspec.yaml':
      'name: go_router\nenvironment:\n  sdk: ^3.11.0\n',
  'packages/go_router/lib/go_router.dart': '''
class GoRoute {
  GoRoute({required this.path});
  final String path;
}
''',
  'lib/app.dart': '''
import 'package:go_router/go_router.dart';
import 'package:service_api/api.dart';

final routes = [GoRoute(path: '/'), GoRoute(path: '/items')];

Future<int> load(DefaultApi api) async =>
    await api.listItems() + await api.createItemWithHttpInfo();
''',
  'test/helpers.dart': '''
import 'package:test/test.dart';

void checkOne(int x) => expect(x, 1);
''',
  'test/app_test.dart': '''
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('items', () {
    test('list', () => expect(1, 1));
    test('create', () => checkOne(1));
    test('no assertion', () {});
    test('skipped', () => expect(1, 1), skip: true);
    test('marks skip', () {
      markTestSkipped('later');
      expect(1, 1);
    });
  });
  test('home', () => expect(1, 1));
}
''',
  'test/broken_test.dart': '''
import 'package:test/test.dart';

void main() {
  test('passes', () => expect(1, 1));
  test('fails', () => expect(1, 2));
}
''',
};

List<Map<String, Object>> features(List<String> items, List<String> home) => [
  {
    'name': 'Items',
    'operations': ['listItems', 'create-item'],
    'routes': ['/items'],
    'provenBy': items,
  },
  {
    'name': 'Home',
    'routes': ['/'],
    'provenBy': home,
  },
];

Future<List<String>> problemsFor(
  List<Map<String, Object>> features, {
  bool run = true,
}) async {
  final root = fixture({
    ...app,
    'openapi/openapi.json': jsonEncode(spec),
    'features.json': jsonEncode(features),
  });
  pubGet(root);
  return await featureProblems(root, run: run);
}

void main() {
  test('a complete map with live proofs passes', () async {
    expect(
      await problemsFor(
        features(
          ['test/app_test.dart:items list', 'test/app_test.dart:items create'],
          ['test/app_test.dart:home'],
        ),
      ),
      isEmpty,
    );
  });

  test('operations and routes are read from lib/, both ways', () async {
    final problems = await problemsFor([
      {
        'name': 'Items',
        'operations': ['listItems', 'healthz'],
        'routes': ['/items', '/gone'],
        'provenBy': ['test/app_test.dart:items list'],
      },
    ], run: false);
    expect(problems, [
      'operation create-item is called from lib/ but belongs to no feature',
      'route / is in lib/ but belongs to no feature',
      'operation healthz is listed but lib/ never calls it',
      'route /gone is listed but no GoRoute has this path',
    ]);
  });

  test('proofs that cannot fail, skip or do not exist are rejected', () async {
    final problems = await problemsFor(
      features(
        [
          'test/app_test.dart:items no assertion',
          'test/app_test.dart:items skipped',
          'test/app_test.dart:items marks skip',
          'test/app_test.dart:list',
          'test/missing_test.dart:x',
          'lib/app.dart:x',
        ],
        ['test/app_test.dart:home'],
      ),
      run: false,
    );
    expect(problems, [
      contains('cannot fail'),
      contains('is skipped'),
      contains('can skip itself'),
      contains('no test with exactly this name'),
      contains('no such file'),
      contains('is not test/<file>_test.dart:<full test name>'),
    ]);
  });

  test('a proof fails when anything in its file fails', () async {
    final problems = await problemsFor(
      features(['test/broken_test.dart:passes'], ['test/app_test.dart:home']),
    );
    const failed = 'a test in test/broken_test.dart failed or errored';
    expect(problems, ['test/broken_test.dart:passes: $failed']);
  });

  test('names are matched exactly, not as substrings', () {
    expect(Proof.parse('test/a_test.dart:x: y')?.name, 'x: y');
    expect(Proof.parse('test/a.dart:x'), isNull);
  });
}
