import 'dart:convert';
import 'dart:io';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:test/test.dart';

import 'conformance/schema_check.dart';

void main() {
  final document = object(jsonDecode(
      File('../../../fixtures/conformance/action-scenarios.json')
          .readAsStringSync()));
  final scenarios = objects(document['scenarios']);
  final checker = SchemaCheck(Directory('../../../schemas/v0.1'));
  test('action_scenario_inventory_is_nonempty', () {
    expect(scenarios.length, 28);
  });
  for (final scenario in scenarios) {
    test('action_scenario_client_observable_${scenario['name']}', () {
      final seed = Message.fromJson(object(scenario['seedMessage']));
      final store = BlockStore()..apply(SyncMessage(seed));
      final requests = objects(scenario['requests']);
      final results = objects(scenario['results']);
      expect(requests.length, results.length);
      for (var i = 0; i < requests.length; i++) {
        expect(checker.accepts(requests[i], 'action.schema.json'), isTrue);
        expect(checker.accepts(results[i], 'action.schema.json'), isTrue);
        expect(results[i]['actionId'], requests[i]['id']);
        final result = ActionResult.fromJson(results[i]);
        expect(result.toJson(), results[i]);
        expect(result['resume'] != null && result['followUp'] != null, isFalse);
        for (final patch in objects(result['patches'])) {
          store.apply(ActionPatch(
              patch['messageId'] as String,
              patch['blockId'] as String,
              patch['rev'] as int,
              object(patch['patch'])));
        }
        if (result['resume'] != null) {
          expect(result['patches'], isNull);
          expect(object(result['resume'])['messageId'], seed.id);
          // A resume result cannot itself change the answer or create a user bubble.
          expect(store.snapshot.messages.length, 1);
        }
      }
      final hasResume = results.any((r) => r['resume'] != null);
      if (!hasResume) {
        expect(store.snapshot.messages[seed.id]!.json,
            scenario['expectedMessage']);
      } else {
        expect(store.snapshot.messages[seed.id]!.json, seed.json);
      }
    });
  }
  // Server-only guarantees are deliberately not simulated by the client runner.
  const serverOnly = {
    'authorizeDecisions': 'authorization and ordering execute on the server',
    'executeCount': 'the client cannot observe actual business side effects',
    'destructive':
        'handler authorization and atomic reservation are server responsibilities',
    'concurrentAnswer':
        'server concurrency is validated by Rust dispatcher tests',
  };
  test('action_server_only_assertions_have_explicit_reasons', () {
    expect(serverOnly.values.every((reason) => reason.isNotEmpty), isTrue);
    for (final scenario in scenarios) {
      for (final key in scenario.keys) {
        expect({
          'name',
          'seedMessage',
          'requests',
          'results',
          'expectedMessage',
          ...serverOnly.keys
        }, contains(key));
      }
    }
  });
}
