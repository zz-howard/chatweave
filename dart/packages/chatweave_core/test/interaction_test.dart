import 'dart:async' as async;
import 'dart:convert';
import 'dart:io';
import 'package:chatweave_core/chatweave_core.dart';
import 'package:chatweave_core/testing.dart';
import 'package:test/test.dart';

Message seed() {
  final block = jsonDecode(
      File('../../../fixtures/conformance/blocks/choice-valid.json')
          .readAsStringSync());
  return Message.fromJson({
    'id': 'm',
    'conversationId': 'c',
    'protocolVersion': '0.1',
    'role': 'assistant',
    'status': 'complete',
    'rev': 1,
    'createdAt': '2026-10-26T09:30:00Z',
    'fallbackText': '问题',
    'blocks': [block]
  });
}

void main() {
  test('timeout_retry_reuses_frozen_intent_id', () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final persistence = MemoryStore();
    final pending = async.Completer<ActionSubmission>();
    final transport = ScriptedTransport(connections: [], actions: [
      (_) => pending.future,
      (_) async => throw StateError('offline'),
    ]);
    var ids = 0;
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        nextId: () => 'intent_${++ids}',
        transport: transport,
        timeout: Duration.zero);
    await controller.submit('m', 'b1', {
      'selected': ['bj']
    });
    expect(controller.stateFor('m', 'b1').phase, InteractionPhase.retryable);
    await controller.retry('m', 'b1');
    expect(transport.requests.length, 2);
    expect(transport.requests.first.json, transport.requests.last.json);
    expect(ids, 1);
    pending.complete(const ActionSubmission.queued());
    await controller.dispose();
    await persistence.dispose();
    await store.dispose();
  });
  test('memory_implementations_pass_contract_suite', () async {
    final report = await runContractSuite(MemoryStore());
    expect(report.executed, 5);
    expect(report.failures, isEmpty);
    expect(report.passed, isTrue);
  });
  test('contract_suite_rejects_broken_adapters', () async {
    final report = await runContractSuite(_DropsClientState());
    expect(report.passed, isFalse);
    expect(report.failures.map((f) => f.name),
        contains('complete_intent_and_stop_marker_roundtrip'));
  });
  test('double_click_creates_one_intent_and_request', () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final persistence = MemoryStore();
    final pending = async.Completer<ActionSubmission>();
    var ids = 0;
    var durableBeforeTransport = false;
    final transport = ScriptedTransport(connections: [], actions: [
      (request) async {
        durableBeforeTransport =
            (await persistence.loadClientState('m')).intents['b1']?.id ==
                request.id;
        return pending.future;
      }
    ]);
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        transport: transport,
        nextId: () => 'intent_${++ids}');
    final first = controller.submit('m', 'b1', {
      'selected': ['bj']
    });
    final second = controller.submit('m', 'b1', {
      'selected': ['sh']
    });
    await async.Future<void>.delayed(Duration.zero);
    expect(durableBeforeTransport, isTrue,
        reason: 'intent must be durable before transport');
    expect(ids, 1);
    expect(transport.requests.length, 1);
    expect(controller.stateFor('m', 'b1').phase, InteractionPhase.submitting);
    expect(
        object(
            store.snapshot.messages['m']!.blocks.first.data['state'])['status'],
        'open');
    pending.complete(ActionSubmission.result(ActionResult.fromJson({
      'actionId': 'intent_1',
      'status': 'completed',
      'patches': [
        {
          'messageId': 'm',
          'blockId': 'b1',
          'rev': 2,
          'patch': {
            'data': {
              'state': {
                'status': 'resolved',
                'selected': ['sh'],
                'resolvedAt': '2026-10-26T09:31:00Z'
              }
            }
          }
        },
      ]
    })));
    await async.Future.wait([first, second]);
    expect(
        object(store.snapshot.messages['m']!.blocks.first.data['state'])[
            'selected'],
        ['sh']);
  });
  test('action_intent_survives_restart_and_retry_preserves_frozen_payload',
      () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final persistence = MemoryStore();
    final transport = ScriptedTransport(connections: [], actions: [
      (_) async => throw StateError('disconnect'),
      (_) async => const ActionSubmission.queued(),
    ]);
    var ids = 0;
    final original = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        transport: transport,
        nextId: () => 'intent_${++ids}');
    final payload = <String, Object?>{
      'selected': ['bj']
    };
    await original.submit('m', 'b1', payload);
    payload['selected'] = ['sh'];
    await original.dispose();
    final restored = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        transport: transport,
        nextId: () => 'intent_${++ids}');
    await restored.restore('m');
    expect(ids, 1);
    expect(transport.requests.map((r) => r.id).toSet(), {'intent_1'});
    expect(transport.requests.last['payload'], {
      'selected': ['bj']
    });
    expect(restored.stateFor('m', 'b1').phase, InteractionPhase.queued);
  });
  test('readonly_never_emits_action_or_message', () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        nextId: () => throw StateError('must not allocate'));
    await controller.submit('m', 'b1', {
      'selected': ['bj']
    });
    expect(store.snapshot.messages.length, 1);
  });
  test('duplicate_action_patch_is_noop', () {
    final store = BlockStore()..apply(SyncMessage(seed()));
    const patch = ActionPatch('m', 'b1', 2, {
      'data': {
        'state': {
          'status': 'resolved',
          'resolvedAt': '2026-10-26T09:31:00Z',
          'selected': ['bj']
        }
      }
    });
    final first = store.apply(patch);
    validateMessage(first.messages['m']!.json);
    expect(identical(store.apply(patch), first), isTrue);
  });
  test('unavailable_keeps_intent_locked_and_retry_uses_same_id', () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final persistence = MemoryStore();
    final transport = ScriptedTransport(connections: [], actions: [
      (_) async => ActionSubmission.result(ActionResult.fromJson({
            'actionId': 'intent',
            'status': 'failed',
            'error': {'code': 'unavailable', 'message': '正在确认'}
          })),
      (_) async => const ActionSubmission.queued(),
    ]);
    var ids = 0;
    var refreshes = 0;
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        transport: transport,
        nextId: () {
          ids++;
          return 'intent';
        },
        onRefresh: (_) async {
          refreshes++;
        });
    await controller.submit('m', 'b1', {
      'selected': ['bj']
    });
    expect(controller.stateFor('m', 'b1').phase, InteractionPhase.retryable);
    await controller.submit('m', 'b1', {
      'selected': ['sh']
    });
    expect(transport.requests.length, 1);
    await controller.retry('m', 'b1');
    expect(ids, 1);
    expect(transport.requests.map((r) => r.id).toSet(), {'intent'});
    expect(refreshes, 1);
  });
  test('submit_after_restart_recovers_intent_before_allocating_id', () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final persistence = MemoryStore();
    final saved = ActionRequest.fromJson({
      'id': 'saved',
      'protocolVersion': '0.1',
      'type': 'choice.select',
      'target': 'weather.select',
      'context': {'conversationId': 'c', 'messageId': 'm', 'blockId': 'b1'},
      'payload': {
        'selected': ['bj']
      }
    });
    await persistence.saveClientState('m', ClientState(intents: {'b1': saved}));
    final transport = ScriptedTransport(
        connections: [],
        actions: [(_) async => const ActionSubmission.queued()]);
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: persistence,
        transport: transport,
        nextId: () => throw StateError('must restore first'));
    await controller.submit('m', 'b1', {
      'selected': ['sh']
    });
    expect(transport.requests.single.id, 'saved');
    expect(transport.requests.single['payload'], {
      'selected': ['bj']
    });
  });
  test('follow_up_subscribes_new_message_once', () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    final followed = <String>[];
    final transport = ScriptedTransport(connections: [], actions: [
      (_) async => ActionSubmission.result(ActionResult.fromJson({
            'actionId': 'intent',
            'status': 'accepted',
            'followUp': {'messageId': 'new_message'}
          }))
    ]);
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        nextId: () => 'intent',
        onFollowUp: (id) async {
          followed.add(id);
        });
    await async.Future.wait([
      controller.submit('m', 'b1', {
        'selected': ['bj']
      }),
      controller.submit('m', 'b1', {
        'selected': ['sh']
      })
    ]);
    expect(followed, ['new_message']);
  });

  test('rejected_open_block_restores_controls_and_error_and_allows_new_intent',
      () async {
    final store = BlockStore()..apply(SyncMessage(seed()));
    var ids = 0;
    final transport = ScriptedTransport(connections: [], actions: [
      (request) async => ActionSubmission.result(ActionResult.fromJson({
            'actionId': request.id,
            'status': 'rejected',
            'error': {'code': 'invalid_payload', 'message': '请选择有效城市'}
          })),
      (_) async => const ActionSubmission.queued(),
    ]);
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        nextId: () => 'intent_${++ids}');
    await controller.submit('m', 'b1', {
      'selected': ['invalid']
    });
    expect(controller.stateFor('m', 'b1').locked, isFalse);
    expect(controller.stateFor('m', 'b1').error, '请选择有效城市');
    await controller.submit('m', 'b1', {
      'selected': ['bj']
    });
    expect(transport.requests.map((r) => r.id), ['intent_1', 'intent_2']);
  });
  test('accepted_resume_waits_for_patch_without_user_bubble', () async {
    final original = seed();
    final message = Message.fromJson({
      ...original.json,
      'status': 'paused',
      'rev': 0,
      'lastSeq': 6,
      'interrupt': {
        'id': 'i',
        'stepId': 's',
        'blockId': 'b1',
        'reason': 'input_required'
      },
      'steps': [
        {'id': 's', 'label': '选择城市', 'state': 'awaiting_user', 'blockId': 'b1'}
      ]
    });
    final store = BlockStore()..apply(SyncMessage(message));
    final resumed = <String>[];
    final transport = ScriptedTransport(connections: [], actions: [
      (request) async => ActionSubmission.result(ActionResult.fromJson({
            'actionId': request.id,
            'status': 'accepted',
            'resume': {'messageId': 'm'}
          })),
    ]);
    final controller = InteractionController(
        maxAutomaticRetries: 0,
        store: store,
        persistence: MemoryStore(),
        transport: transport,
        nextId: () => 'intent',
        onResume: (id) async {
          resumed.add(id);
        });
    await controller.submit('m', 'b1', {
      'selected': ['bj']
    });
    expect(resumed, ['m']);
    expect(store.snapshot.messages.length, 1);
    expect(
        object(
            store.snapshot.messages['m']!.blocks.first.data['state'])['status'],
        'open');
    expect(controller.stateFor('m', 'b1').phase, InteractionPhase.submitting);
  });
}

class _DropsClientState extends MemoryStore {
  @override
  async.Future<void> saveClientState(
      String messageId, ClientState state) async {}
}
