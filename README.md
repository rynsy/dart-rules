# dart-rules

`rynsy_rules`: the shared lint rules and verification checks for every Flutter app built from `flutter-app-template`. A rule added here reaches every app through a Renovate PR, and that PR's `make check` shows what the new rule breaks.

The idea: whenever an agent (or a person) gets something wrong, the correction becomes a rule here, not a line in AGENTS.md. A rule is enforced; a sentence in a prompt is not. The twins are [py-rules](https://github.com/rynsy/py-rules) and [go-rules](https://github.com/rynsy/go-rules).

## Use it

`pubspec.yaml`:

```yaml
dev_dependencies:
  rynsy_rules:
    git:
      url: https://github.com/rynsy/dart-rules.git
      ref: v0.1.0
```

`analysis_options.yaml`, exactly:

```yaml
include: package:rynsy_rules/analysis_options.yaml
```

`Makefile` (CI must run these targets too):

```make
rules:
	dart run rynsy_rules check

features:
	dart run rynsy_rules features
```

## What it sets

`lib/analysis_options.yaml`: very_good_analysis with `strict-casts`, `strict-inference` and `strict-raw-types`; package imports only; no doc comment required on public members (an app, not a library); the generated client (`packages/**`), `*.g.dart`, `build/`, `android/` and `web/` are not analyzed.

## Checks

`dart run rynsy_rules check`:

- **RYD001**: comments are errors except:
  - `///` doc comments attached to a declaration (a `///` inside a body is not one);
  - `// TODO(#<issue>)` and `// ponytail: <ceiling>`, each with at most two continuation lines;
  - a suppression (`// ignore:`, `// ignore_for_file:`, `// coverage:ignore-*`) on the line directly under a `// TODO(#<issue>)`.

  Block comments and `/** */` count, whatever they say. Files come from `git ls-files`; the generated client under `packages/` and `*.g.dart` are skipped.
- **RYD002**: `DateTime.now`, `DateTime.timestamp`, `Stopwatch()` and `sleep` in `lib/` outside `lib/main.dart`. Resolved, so an import prefix or a tear-off does not hide them. Inject a clock from `main.dart`; wait on the event. Timers (`Future.delayed`, `Timer`) stay allowed. The analyzer's `// ignore:` cannot silence this check.
- **RYD003**: the root `analysis_options.yaml` is exactly the include above, and no other tracked `analysis_options.yaml` exists outside `packages/`. `flutter pub add` and `pub remove` rewrite the file (they add excludes); restore it from git afterwards.

`dart run rynsy_rules features [--openapi openapi/openapi.json] [--features features.json]`:

- **The feature set is read from the code**, resolved: every operation of the generated client (`package:service_api`, a method on an `*Api` class whose name is the lowerCamel `operationId`, or that plus `WithHttpInfo`) called from `lib/`, and the `path` of every `GoRoute` in `lib/` (it must be a string literal). Each must belong to a feature, and each operation or route a feature lists must be in the code.
- **Every feature names a proving test** as `test/<file>_test.dart:<full name>`, where the full name is the group names and the test name joined by spaces, as `flutter test` reports it. Statically, the proof is a `test` or `testWidgets` call with literal names, is not skipped (`skip:` on it or a group), does not call `markTestSkipped`, and can fail (`expect`, `expectLater`, `fail`, or a top-level function in `test/` that reaches one).
- **The proofs run.** All proof files go through one `flutter test --reporter json` run (`dart test` for a package without Flutter). A proof passes only if a test with exactly that name finished `success`, not skipped, and nothing else in its file failed or errored.

`features.json`:

```json
[{"name": "Items list", "operations": ["listItems"], "routes": ["/"], "provenBy": ["test/home_screen_test.dart:home lists items"]}]
```

Known ceilings of the static part (the run catches none of them, because the test does pass): an assertion in dead code, an early `return` before the assertions, and a helper whose name matches an asserting one elsewhere in `test/`.

## Rules ledger

| ID | Forbids | Fix | Came from |
|---|---|---|---|
| RYD001 | comments other than doc comments, `TODO(#n)`, `ponytail:`; a suppression without a TODO | a name, a type or a test | the .NET, Python and Go comment rules |
| RYD002 | `DateTime.now/timestamp`, `Stopwatch()`, `sleep` in `lib/` | inject a clock; wait on the event | the clock bans in py-rules and go-rules; lifelog-app's drifting goldens (2026-11-12) |
| RYD003 | a local or nested analyzer config | add the rule here | three copies of the same `analysis_options.yaml` |
