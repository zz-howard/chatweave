import 'dart:convert';
import 'dart:io';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:test/test.dart';

void main() {
  for (final type in builtinTypes) {
    test('runtime_${type}_rejects_wrong_field_type', () {
      final b = object(jsonDecode(
          File('../../../fixtures/conformance/blocks/$type-valid.json')
              .readAsStringSync()));
      final data = {...object(b['data'])};
      final key = switch (type) {
        'markdown' => 'text',
        'metric' => 'label',
        'metric_group' => 'metrics',
        'dataset' => 'rows',
        'time_series' => 'series',
        'comparison' => 'subjects',
        'status' => 'state',
        'choice' => 'options',
        'confirmation' => 'action',
        'form_intent' => 'fields',
        _ => throw StateError(type),
      };
      data[key] = true;
      expect(() => validateBlock({...b, 'data': data}),
          throwsA(isA<ProtocolError>()));
    });
  }
  test('runtime_interaction_state_rejects_cross_type_answer', () {
    final b = object(jsonDecode(
        File('../../../fixtures/conformance/blocks/choice-valid.json')
            .readAsStringSync()));
    final data = {
      ...object(b['data']),
      'state': {
        'status': 'resolved',
        'outcome': 'confirm',
        'resolvedAt': '2026-10-26T09:31:00Z',
      }
    };
    expect(() => validateBlock({...b, 'data': data}),
        throwsA(isA<ProtocolError>()));
  });
  test('consumer_restore_sync_snapshot_and_patch_preserve_bad_block', () {
    final good = {
      'id': 'good',
      'type': 'markdown',
      'schemaVersion': 1,
      'data': {'text': '天气晴朗'},
    };
    for (final badData in <Object?>[
      true,
      {'label': true},
      null
    ]) {
      final bad = {
        'id': 'bad',
        'type': 'metric',
        'schemaVersion': 1,
        'fallbackText': '天气暂不可用',
        'data': badData,
      };
      final message = Message.fromJson({
        'id': 'm',
        'status': 'complete',
        'rev': 1,
        'blocks': [good, bad],
      });
      final restored = FoldState()..restore(message, 1);
      expect(restored.message.blocks.last.json, bad);
      expect(() => FoldState(strictBlocks: true)..restore(message, 1),
          throwsA(isA<ProtocolError>()));
      final store = BlockStore()
        ..apply(SyncMessage(Message.fromJson({
          ...message.json,
          'status': 'streaming',
          'rev': 0,
          'lastSeq': 1,
        })))
        ..apply(SyncMessage(message));
      store.apply(ApplyStream(StreamEvent.fromJson({
        'type': 'message.snapshot',
        'messageId': 'm',
        'seq': 1,
        'message': message.json,
      })));
      store.apply(const ActionPatch('m', 'bad', 2, {
        'data': {'value': false},
      }));
      final next = store.snapshot.messages['m']!;
      expect(next.rev, 2);
      expect(next.blocks.first.json, good);
      expect(next.blocks.last['fallbackText'], '天气暂不可用');
      expect(() => validateBlock(next.blocks.last.json),
          throwsA(isA<ProtocolError>()));
    }
  });
  test('diagnostics_export_excludes_payload_and_errors', () {
    final store = BlockStore();
    store.recordDiagnostic('actions', 'm/b', {
      'phase': 'confirming',
      'actionId': 'intent',
      'payload': {'secret': 'private'},
      'error': 'private',
    });
    final export = jsonEncode(store.inspect());
    expect(export, contains('intent'));
    expect(export, isNot(contains('private')));
    expect(export, isNot(contains('payload')));
  });
}
