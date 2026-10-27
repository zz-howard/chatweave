import 'dart:convert';
import 'dart:io';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:test/test.dart';
import 'package:chatweave_core/src/wire_schemas.dart';

import 'schema_check.dart';

void main() {
  final root = Directory('../../..');
  final fixtures = Directory('${root.path}/fixtures/conformance');
  final manifest = object(
      jsonDecode(File('${fixtures.path}/manifest.json').readAsStringSync()));
  final cases = objects(manifest['cases']);
  final checker = SchemaCheck(Directory('${root.path}/schemas/v0.1'));
  Object? read(String file) =>
      jsonDecode(File('${fixtures.path}/$file').readAsStringSync());
  test('runtime_schema_copy_matches_repository', () {
    for (final entry in wireSchemas.entries) {
      final source = jsonDecode(
          File('${root.path}/schemas/v0.1/${entry.key}').readAsStringSync());
      expect(entry.value, source, reason: entry.key);
    }
  });
  test('schemas_every_keyword_is_supported', checker.assertRepositorySupported);
  test('schema_unknown_keyword_fails_closed', () {
    expect(() => checker.assertSupported({'futureKeyword': true}),
        throwsUnsupportedError);
  });
  test('manifest_all_cases_exercised', () {
    expect(cases, isNotEmpty);
    expect(cases.map((c) => c['name']).toSet().length, cases.length);
    expect(cases.map((c) => c['kind']).toSet(), {
      'block',
      'message',
      'event',
      'events',
      'action',
      'generation',
      'capabilities'
    });
  });
  for (final c in cases) {
    test('conformance_${c['name']}', () {
      final kind = c['kind'];
      final reject = c['rejectAt'];
      if (kind == 'events') {
        final events = File('${fixtures.path}/${c['events']}')
            .readAsLinesSync()
            .where((line) => line.trim().isNotEmpty)
            .map((line) => StreamEvent.fromJson(object(jsonDecode(line))))
            .toList();
        expect(events, isNotEmpty);
        if (reject == 'schema') {
          expect(
              events
                  .any((e) => !checker.accepts(e.json, c['schema'] as String)),
              isTrue);
          return;
        }
        Message run() => fold(events,
            legacySteps: c['legacySteps'] == true, strictBlocks: true);
        if (reject != null) {
          final code =
              reject == 'limits' ? 'limit_exceeded' : semanticCodes[c['name']];
          expect(code, isNotNull,
              reason: 'every semantic rejection needs a specific code');
          expect(
              run,
              throwsA(
                  isA<ProtocolError>().having((e) => e.code, 'code', code)));
        } else {
          expect(run().json, read(c['expected'] as String));
        }
        return;
      }
      final value = object(read(c['file'] as String));
      if (reject == 'schema') {
        expect(checker.accepts(value, c['schema'] as String), isFalse);
        return;
      }
      void validate() {
        if (kind == 'block') validateBlock(value);
        if (kind == 'message') validateMessage(value);
        if (kind == 'event') const Limits().checkEvent(value);
      }

      if (reject != null) {
        final code =
            reject == 'limits' ? 'limit_exceeded' : semanticCodes[c['name']];
        expect(code, isNotNull);
        expect(validate,
            throwsA(isA<ProtocolError>().having((e) => e.code, 'code', code)));
      } else {
        if (c['mode'] != 'consumer') {
          expect(checker.accepts(value, c['schema'] as String), isTrue);
        }
        validate();
        expect(WireModel(value).toJson(), value);
      }
    });
  }
}

const semanticCodes = <String, String>{
  'invalid-seq-gap': 'seq_gap',
  'invalid-duplicate-block-id': 'duplicate_block_id',
  'invalid-delta-before-start': 'unknown_block',
  'invalid-duplicate-step-id': 'duplicate_step_id',
  'invalid-finish-unknown-step': 'unknown_step',
  'invalid-finish-step-twice': 'step_ended',
  'invalid-end-with-running-step': 'unfinished_step',
  'invalid-step-parent-missing': 'invalid_parent',
  'invalid-step-parent-not-delegate': 'invalid_parent',
  'invalid-step-parent-ended': 'invalid_parent',
  'invalid-step-parent-self': 'invalid_parent',
  'invalid-step-depth-four': 'step_depth',
  'invalid-delegate-finished-before-child': 'unfinished_child',
  'invalid-pause-with-open-block': 'pause_open_block',
  'invalid-pause-with-other-running-step': 'pause_other_step',
  'invalid-pause-with-noninteraction': 'invalid_interrupt',
  'invalid-paused-unrelated-event': 'paused_event',
  'invalid-paused-unrelated-patch': 'paused_event',
  'invalid-resume-before-resolved': 'paused_event',
  'invalid-resume-interrupt-mismatch': 'interrupt_mismatch',
  'invalid-resume-not-adjacent': 'paused_event',
  'invalid-end-with-awaiting-user': 'paused_event',
  'invalid-block-count-mismatch': 'block_count',
  'invalid-end-with-pending-block': 'unfinished_block',
  'invalid-rev-gap': 'rev_gap',
  'invalid-rev-on-streaming-patch': 'unexpected_rev',
  'invalid-message-id-mismatch': 'message_mismatch',
  'interrupt-step-mismatch': 'invalid_interrupt',
  'interrupt-block-missing': 'invalid_interrupt',
  'snapshot-step-parent-missing': 'invalid_parent',
  'invalid-pause-missing-step': 'unknown_step',
  'invalid-pause-closed-block': 'invalid_interrupt',
  'invalid-reused-interrupt-id': 'duplicate_interrupt_id',
  'invalid-patch-delete-required-data': 'validation_failed',
};
