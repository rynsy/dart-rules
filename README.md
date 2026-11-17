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
      ref: v0.2.0
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
  - a suppression (`// ignore:`, `// ignore_for_file:`, `// coverage:ignore-*`) on the line directly under a `// TODO(#<issue>)` line (not under a continuation or a `ponytail:`).

  Suppressions are checked first, so `/// ignore:` and a suppression inside a `ponytail:` continuation are findings. Block comments and `/** */` count, whatever they say. Files come from `git ls-files`; only the generated client, `packages/service_api/`, is skipped (`*.g.dart` gets no exemption: there is no build_runner).
- **RYD002**: `DateTime.now`, `DateTime.timestamp`, `Stopwatch()` (and any subclass of it), `Timeline.now` and `sleep` in `lib/` outside `lib/main.dart`. Resolved, so an import prefix or a tear-off does not hide them. Nothing in `lib/` may import or export `main.dart`, so it cannot hand the clock on. Inject a clock from `main.dart`; wait on the event. Timers (`Future.delayed`, `Timer`) stay allowed. The analyzer's `// ignore:` cannot silence this check.
- **RYD003**: the root `analysis_options.yaml` is exactly the include above, and no other tracked `analysis_options.yaml` exists outside `packages/service_api/`. The pubspec cannot swap the checker or its config: no `dependency_overrides`, no `pubspec_overrides.yaml`, `rynsy_rules` only as a git dependency on this repo, and no path dependency except `packages/service_api`. `flutter pub add` and `pub remove` rewrite the file (they add excludes); restore it from git afterwards.

`dart run rynsy_rules features [--openapi openapi/openapi.json] [--features features.json]`:

- **The feature set is read from the code**, resolved: every operation of the generated client (`package:service_api`, a method on an `*Api` class whose name is the lowerCamel `operationId`, or that plus `WithHttpInfo`) called from `lib/`, and the `path` of every `GoRoute` in `lib/`, including through a typedef or a subclass (a string literal, in the creation or the `super(...)` call). A dynamic call in `lib/` is a finding. Each operation and route must belong to a feature, and each one a feature lists must be in the code.
- **Every feature names a proving test** as `test/<file>_test.dart:<full name>`, where the full name is the group names and the test name joined by spaces, as `flutter test` reports it. Statically (resolved), the proof is a `test` or `testWidgets` call with literal names, is not skipped (`skip:` on it or a group), does not call `markTestSkipped`, and can fail: it calls `expect`, `expectLater` or `fail` from the test packages, or a top-level function in `test/` that reaches one (a local function named `expect` does not count).
- **A feature's proofs reach its code**: for every operation and route the feature lists, at least one of its proofs imports (transitively) a `lib/` file where that call or route is.
- **The proofs run.** All proof files go through one `flutter test --reporter json` run (`dart test` for a package without Flutter). A proof passes only if a test with exactly that name finished `success`, not skipped, and nothing else in its file failed or errored.

`features.json`:

```json
[{"name": "Items list", "operations": ["listItems"], "routes": ["/"], "provenBy": ["test/home_screen_test.dart:home lists items"]}]
```

Known ceilings (the run catches none of them, because the test does pass):

- an assertion in dead code, an early `return` before it, or a tautology (`expect(x, anything)`);
- a proof that imports the right file but never exercises the call;
- a raw `http` call to the service from `lib/` is not an operation (the client is the only thing read);
- every gate is a file in the PR it judges (Makefile, `ci.yml`, this package's pin); the review of those files is the last gate.

## Rules ledger

| ID | Forbids | Fix | Came from |
|---|---|---|---|
| RYD001 | comments other than doc comments, `TODO(#n)`, `ponytail:`; a suppression without a TODO | a name, a type or a test | the .NET, Python and Go comment rules |
| RYD002 | `DateTime.now/timestamp`, `Stopwatch()`, `sleep` in `lib/` | inject a clock; wait on the event | the clock bans in py-rules and go-rules; lifelog-app's drifting goldens (2026-11-12) |
| RYD003 | a local or nested analyzer config; overrides or another source for this package | add the rule here | three copies of the same `analysis_options.yaml`; adversarial review, 2026-11-17 |
